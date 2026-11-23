! renderer_v3.f90 -- Forge3D v3.0 Phase 2 renderer (module
! renderer_v3_3d).  This is the NEW default renderer; the legacy
! renderer (renderer_3d, ADR-1 frozen) is untouched.
!
! Pipeline (deferred / visibility-buffer design):
!   1. Vertex stage: every scene-object triangle is transformed by
!      its object's world matrix and the camera view-projection in
!      real64.  Screen positions are then quantised to 28.4 fixed
!      point (stored in int64; int32 would overflow the edge-function
!      products at large resolutions).
!   2. Pass 1 (visibility): triangles are binned into 32x32 tiles and
!      rasterised with incremental int64 edge functions and the
!      TOP-LEFT fill rule into a visibility buffer.  Tiles are
!      rendered completely and independently, triangles in scene
!      order within a tile, under an OpenMP parallel-do over tiles.
!      Tiles write disjoint pixels and the per-tile order is fixed,
!      so the output is byte-identical for any thread count.
!   3. Pass 2 (shade): pixels are walked once; for the winning
!      triangle the fragment input is reconstructed from the stored
!      corner data with PERSPECTIVE-CORRECT interpolation
!      (attr = sum(l_i * attr_i / w_i) / sum(l_i / w_i)) and handed
!      to fragment_v3_3d's frag_shade, which writes linear RGB.
!
! Depth representation (documented choice): the depth buffer stores
! 1/w (real32), i.e. the perspective-correct interpolation weight
! itself.  LARGER 1/w is CLOSER; a fragment wins iff its interpolated
! 1/w is strictly greater than the stored value.  Strict comparison
! plus scene order gives first-triangle-wins on exact depth ties.
! The buffer is cleared to 0 (w = infinity).
!
! Limitations (by design, this phase): the visibility buffer holds
! OPAQUE geometry only.  (v3.0 Phase 4: alpha-masked fragments
! re-shade deeper layers inside shade_pass, and alpha-blend
! triangles -- excluded from the visibility pass -- are drawn by
! the sorted, single-threaded blend_pass after shading; see both
! procedures.  The visibility buffer itself remains opaque-only.)
! Triangles crossing the near plane or with |NDC| > 4 are dropped
! rather than clipped (the legacy path keeps full homogeneous
! clipping; v3 clipping is later work).  Sprites / text / particles
! are not part of the v3 path yet (main falls back to legacy for
! such scenes).  (v3.0 Phase 3: per-light shadow maps are built
! per frame in render_core via shadow_v3_3d, and bloom + tone
! mapping run on the float buffer inside v3_quantize_to_fb via
! post_v3_3d -- see there.)
!
! Framebuffer (ADR-4): v3_buffer%rgb is real32 LINEAR RGB.  Values
! stay linear through SSAA downsampling; the output transform
! (bloom + tonemap, then sRGB encode + quantisation to 0..255
! bytes) happens only in v3_quantize_to_fb at output.
module renderer_v3_3d
    use, intrinsic :: iso_fortran_env, only: real32, int32, int64
    use math_3d
    use mesh_3d, only: Mesh, Triangle, compute_triangle_normal
    use camera_3d, only: Camera
    use scene_3d, only: Scene
    use renderer_3d, only: FrameBuffer
    use fragment_v3_3d, only: frag_in, frag_shade, frag_shade_a
    use post_v3_3d, only: post_v3_apply, post_v3_linear_to_byte
    use shadow_v3_3d, only: shadow_v3_build
    implicit none
    private
    public :: v3_buffer, v3_init, v3_free, v3_render_scene, &
              v3_render_scene_fb, v3_quantize_to_fb, &
              v3_perspective_interp, V3_TILE

    integer, parameter :: V3_TILE = 32
    ! 28.4 fixed point: 4 fractional bits, coordinates in int64.
    integer(int64), parameter :: FP_SHIFT = 4_int64
    integer(int64), parameter :: FP_ONE = 16_int64

    type :: v3_buffer
        integer :: width = 0
        integer :: height = 0
        ! Linear RGB output (3, width, height), real32, ADR-4.
        real(real32), allocatable :: rgb(:, :, :)
        ! Visibility buffer: winning triangle index (1-based global,
        ! 0 = background), two barycentric lambdas (the third is
        ! 1 - l1 - l2), and depth as 1/w.
        integer(int32), allocatable :: vis_tri(:, :)
        real(real32), allocatable :: lam(:, :, :)   ! (2, width, height)
        real(real32), allocatable :: depth(:, :)    ! 1/w, larger = closer
        ! Debug / test hooks: per-pixel coverage count (number of
        ! triangles whose fill-rule test covered the pixel, before
        ! the depth test) and the perspective-correct interpolated
        ! UV / world position from the shade pass.
        integer, allocatable :: cover(:, :)
        real(real32), allocatable :: uv_dbg(:, :, :)  ! (2, width, height)
        real(real32), allocatable :: pos_dbg(:, :, :)  ! (3, width, height)
        ! Phase 4: 1 where a pixel's rgb came from shading (opaque
        ! shade pass or the transparent blend pass), 0 for pure
        ! background.  v3_quantize_to_fb uses it so a pixel covered
        ! ONLY by a transparent triangle (vis_tri == 0) is still
        ! output-transformed instead of restored to the raw bg.
        integer, allocatable :: shaded(:, :)
    end type v3_buffer

    ! Transformed triangle store (structure of arrays), filled by the
    ! vertex stage and consumed by both passes.
    type :: tri_store
        integer :: n = 0
        integer(int64), allocatable :: fx(:, :)  ! (3, n) fixed-point x
        integer(int64), allocatable :: fy(:, :)  ! (3, n) fixed-point y
        real(dp), allocatable :: invw(:, :)       ! (3, n) 1/w per corner
        real(dp), allocatable :: wp(:, :, :)      ! (3, 3, n) world pos
        real(dp), allocatable :: nrm(:, :, :)     ! (3, 3, n) world normals
        real(dp), allocatable :: uv(:, :, :)      ! (2, 3, n)
        real(real32), allocatable :: col(:, :)    ! (3, n) base colour 0..1
        integer, allocatable :: mat_id(:)
        integer, allocatable :: obj_id(:)
        integer, allocatable :: alpha_mode(:)  ! Phase 4: obj PBR alpha mode
        integer, allocatable :: shader_id(:)
        logical, allocatable :: backface(:)
        integer, allocatable :: bb(:, :)          ! (4, n) pixel bbox 1-based incl
    end type tri_store

contains

    subroutine v3_init(vb, width, height)
        type(v3_buffer), intent(inout) :: vb
        integer, intent(in) :: width, height
        call v3_free(vb)
        vb%width = width
        vb%height = height
        allocate(vb%rgb(3, width, height))
        allocate(vb%vis_tri(width, height))
        allocate(vb%lam(2, width, height))
        allocate(vb%depth(width, height))
        allocate(vb%cover(width, height))
        allocate(vb%uv_dbg(2, width, height))
        allocate(vb%pos_dbg(3, width, height))
        allocate(vb%shaded(width, height))
        vb%rgb = 0.0_real32
        vb%vis_tri = 0_int32
        vb%lam = 0.0_real32
        vb%depth = 0.0_real32
        vb%cover = 0
        vb%uv_dbg = 0.0_real32
        vb%pos_dbg = 0.0_real32
        vb%shaded = 0
    end subroutine v3_init

    subroutine v3_free(vb)
        type(v3_buffer), intent(inout) :: vb
        if (allocated(vb%rgb)) deallocate(vb%rgb)
        if (allocated(vb%vis_tri)) deallocate(vb%vis_tri)
        if (allocated(vb%lam)) deallocate(vb%lam)
        if (allocated(vb%depth)) deallocate(vb%depth)
        if (allocated(vb%cover)) deallocate(vb%cover)
        if (allocated(vb%uv_dbg)) deallocate(vb%uv_dbg)
        if (allocated(vb%pos_dbg)) deallocate(vb%pos_dbg)
        if (allocated(vb%shaded)) deallocate(vb%shaded)
        vb%width = 0
        vb%height = 0
    end subroutine v3_free

    subroutine store_free(ts)
        type(tri_store), intent(inout) :: ts
        if (allocated(ts%fx)) deallocate(ts%fx)
        if (allocated(ts%fy)) deallocate(ts%fy)
        if (allocated(ts%invw)) deallocate(ts%invw)
        if (allocated(ts%wp)) deallocate(ts%wp)
        if (allocated(ts%nrm)) deallocate(ts%nrm)
        if (allocated(ts%uv)) deallocate(ts%uv)
        if (allocated(ts%col)) deallocate(ts%col)
        if (allocated(ts%mat_id)) deallocate(ts%mat_id)
        if (allocated(ts%obj_id)) deallocate(ts%obj_id)
        if (allocated(ts%alpha_mode)) deallocate(ts%alpha_mode)
        if (allocated(ts%shader_id)) deallocate(ts%shader_id)
        if (allocated(ts%backface)) deallocate(ts%backface)
        if (allocated(ts%bb)) deallocate(ts%bb)
        ts%n = 0
    end subroutine store_free

    subroutine store_alloc(ts, n)
        type(tri_store), intent(inout) :: ts
        integer, intent(in) :: n
        call store_free(ts)
        ts%n = n
        allocate(ts%fx(3, n), ts%fy(3, n), ts%invw(3, n))
        allocate(ts%wp(3, 3, n), ts%nrm(3, 3, n), ts%uv(2, 3, n))
        allocate(ts%col(3, n), ts%mat_id(n), ts%obj_id(n), &
                 ts%alpha_mode(n))
        allocate(ts%shader_id(n), ts%backface(n), ts%bb(4, n))
    end subroutine store_alloc

    ! Perspective-correct interpolation of one scalar attribute:
    !   attr = sum_i(l_i * a_i * invw_i) / sum_i(l_i * invw_i)
    ! Public so tests can pin the formula directly.
    pure function v3_perspective_interp(lam, attr, invw) result(a)
        real(dp), intent(in) :: lam(3), attr(3), invw(3)
        real(dp) :: a, den
        den = lam(1) * invw(1) + lam(2) * invw(2) + lam(3) * invw(3)
        if (abs(den) < 1.0e-30_dp) then
            a = attr(1)
        else
            a = (lam(1) * attr(1) * invw(1) + lam(2) * attr(2) * invw(2) &
                 + lam(3) * attr(3) * invw(3)) / den
        end if
    end function v3_perspective_interp

    ! Thread count: explicit argument wins, then FORGE3D_THREADS,
    ! then 0 = OpenMP default.  Applied via omp_set_num_threads only
    ! in OpenMP builds (the !$ lines are comments otherwise).
    subroutine apply_threads(threads)
        integer, intent(in) :: threads
        character(len=32) :: env
        integer :: n, ios, ln
        n = threads
        if (n <= 0) then
            call get_environment_variable('FORGE3D_THREADS', env, &
                                          length=ln, status=ios)
            if (ios == 0 .and. ln > 0) then
                read(env(1:ln), *, iostat=ios) n
                if (ios /= 0) n = 0
            end if
        end if
        if (n > 0) then
            !$ call omp_set_num_threads(n)
        end if
    end subroutine apply_threads

    ! ------------------------------------------------------------------
    ! Main entry: render scene sc (objects transformed by models(:))
    ! into vb at vb%width x vb%height.  sc%antialias > 1 renders at
    ! antialias x resolution and box-downsamples in linear space.
    ! threads <= 0 means "environment / default".
    ! ------------------------------------------------------------------
    subroutine v3_render_scene(vb, sc, models, threads)
        type(v3_buffer), intent(inout) :: vb
        type(Scene), intent(in) :: sc
        type(mat4), intent(in) :: models(:)
        integer, intent(in), optional :: threads
        type(v3_buffer) :: hi
        integer :: aa, thr, x, y, sx, sy, k
        real(dp) :: acc(3)

        thr = 0
        if (present(threads)) thr = threads
        aa = max(1, sc%antialias)
        if (aa <= 1) then
            call render_core(vb, sc, models, thr)
            return
        end if
        call v3_init(hi, vb%width * aa, vb%height * aa)
        call render_core(hi, sc, models, thr)
        ! Box downsample, averaging in linear space (ADR-4).
        do y = 1, vb%height
            do x = 1, vb%width
                acc = 0.0_dp
                do sy = 1, aa
                    do sx = 1, aa
                        do k = 1, 3
                            acc(k) = acc(k) + real( &
                                hi%rgb(k, (x - 1) * aa + sx, &
                                       (y - 1) * aa + sy), dp)
                        end do
                    end do
                end do
                vb%rgb(:, x, y) = real(acc / real(aa * aa, dp), real32)
            end do
        end do
        ! Visibility/debug buffers are kept from the hi-res pass's
        ! top-left sample of each block so test hooks stay meaningful.
        do y = 1, vb%height
            do x = 1, vb%width
                vb%vis_tri(x, y) = hi%vis_tri((x - 1) * aa + 1, (y - 1) * aa + 1)
                vb%lam(:, x, y) = hi%lam(:, (x - 1) * aa + 1, (y - 1) * aa + 1)
                vb%depth(x, y) = hi%depth((x - 1) * aa + 1, (y - 1) * aa + 1)
                vb%cover(x, y) = hi%cover((x - 1) * aa + 1, (y - 1) * aa + 1)
                vb%uv_dbg(:, x, y) = hi%uv_dbg(:, (x - 1) * aa + 1, (y - 1) * aa + 1)
                vb%pos_dbg(:, x, y) = hi%pos_dbg(:, (x - 1) * aa + 1, (y - 1) * aa + 1)
                vb%shaded(x, y) = hi%shaded((x - 1) * aa + 1, (y - 1) * aa + 1)
            end do
        end do
        call v3_free(hi)
    end subroutine v3_render_scene

    ! Convenience wrapper used by main: render into vb sized to the
    ! legacy framebuffer and quantise back into it.
    subroutine v3_render_scene_fb(fb, sc, models, threads)
        type(FrameBuffer), intent(inout) :: fb
        type(Scene), intent(in) :: sc
        type(mat4), intent(in) :: models(:)
        integer, intent(in), optional :: threads
        type(v3_buffer) :: vb
        integer :: thr
        thr = 0
        if (present(threads)) thr = threads
        call v3_init(vb, fb%width, fb%height)
        call v3_render_scene(vb, sc, models, thr)
        call v3_quantize_to_fb(vb, sc, fb)
        call v3_free(vb)
    end subroutine v3_render_scene_fb

    ! Output transform + quantisation (v3.0 Phase 3, ADR-4): the
    ! linear buffer is first copied and run through the post_v3_3d
    ! float pipeline (true bloom from the scene post chain, then
    ! exposure + tone mapping per sc%tonemap_mode), and each value
    ! is then sRGB-encoded and rounded to a byte -- the ONLY
    ! quantisation point on the v3 path.  Phase 2 wrote linear
    ! values straight to bytes; the sRGB encode added here makes
    ! mid-tones brighter across every v3 render (intended: ADR-4
    ! puts the sRGB output transform at the end of the pipeline).
    ! With tonemap_mode == 0 and no bloom the output is exactly
    ! sRGB(linear): 'none' now means 'no tone curve', not 'no
    ! transform'.  Background pixels keep the scene bg bytes
    ! verbatim (they are already display-referred).  Also resets
    ! the legacy z-buffer (v3 keeps its own depth; post passes that
    ! read z see "infinitely far", as for a cleared buffer).
    subroutine v3_quantize_to_fb(vb, sc, fb)
        type(v3_buffer), intent(in) :: vb
        type(Scene), intent(in) :: sc
        type(FrameBuffer), intent(inout) :: fb
        real(real32), allocatable :: lin(:, :, :)
        integer :: x, y, k
        allocate(lin(3, vb%width, vb%height))
        lin = vb%rgb
        call post_v3_apply(lin, vb%width, vb%height, sc)
        do y = 1, fb%height
            do x = 1, fb%width
                do k = 1, 3
                    ! Background = no opaque winner AND not painted
                    ! by the transparent pass (Phase 4).  Buffers
                    ! built by hand in tests may not carry %shaded;
                    ! fall back to the vis_tri test alone there.
                    if (vb%vis_tri(x, y) == 0_int32 .and. &
                        (.not. allocated(vb%shaded) .or. &
                         vb%shaded(x, y) == 0)) then
                        fb%pixels(k, x, y) = sc%bg(k)
                    else
                        fb%pixels(k, x, y) = &
                            post_v3_linear_to_byte(lin(k, x, y))
                    end if
                end do
            end do
        end do
        deallocate(lin)
        fb%z_buffer = 1.0e10_dp
    end subroutine v3_quantize_to_fb

    ! ------------------------------------------------------------------
    ! Core render at vb's own resolution (no SSAA handling here).
    ! ------------------------------------------------------------------
    subroutine render_core(vb, sc, models, threads)
        type(v3_buffer), intent(inout) :: vb
        type(Scene), intent(in) :: sc
        type(mat4), intent(in) :: models(:)
        integer, intent(in) :: threads
        type(tri_store) :: ts
        integer :: total, oi

        call apply_threads(threads)

        ! Background: linear RGB from the scene bg bytes.
        vb%rgb(1, :, :) = real(sc%bg(1), real32) / 255.0_real32
        vb%rgb(2, :, :) = real(sc%bg(2), real32) / 255.0_real32
        vb%rgb(3, :, :) = real(sc%bg(3), real32) / 255.0_real32
        vb%vis_tri = 0_int32
        vb%lam = 0.0_real32
        vb%depth = 0.0_real32
        vb%cover = 0
        vb%uv_dbg = 0.0_real32
        vb%pos_dbg = 0.0_real32
        vb%shaded = 0

        total = 0
        do oi = 1, sc%n_objects
            if (allocated(sc%objects(oi)%mesh%triangles)) &
                total = total + sc%objects(oi)%mesh%num_triangles
        end do
        if (total <= 0) return
        call store_alloc(ts, total)
        call vertex_stage(ts, sc, models, vb%width, vb%height)
        call rasterize_vis(vb, ts)
        ! v3.0 Phase 3: per-frame shadow maps for the fragment
        ! stage's per-light shadow_v3_factor queries.  The build
        ! records mode 0 (factor 1.0) when the scene disables
        ! shadows, and reuses maps while the shape is unchanged.
        call shadow_v3_build(sc, models)
        call shade_pass(vb, sc, ts)
        ! Phase 4: sorted transparent pass (alpha_mode == 2),
        ! composited over the opaque result in linear space.
        call blend_pass(vb, sc, ts)
        call store_free(ts)
    end subroutine render_core

    ! Vertex stage: world + clip transform in real64, NDC, then
    ! quantise to 28.4 fixed point.  Backface handling: the signed
    ! screen area decides facing; single-sided triangles facing away
    ! are culled (marked with an empty bbox), double-sided ones
    ! (primitive 'plane') are re-wound and flagged backface.
    subroutine vertex_stage(ts, sc, models, width, height)
        type(tri_store), intent(inout) :: ts
        type(Scene), intent(in) :: sc
        type(mat4), intent(in) :: models(:)
        integer, intent(in) :: width, height
        type(mat4) :: mvp, model_view
        integer :: oi, ti, k, g
        type(Triangle) :: tri
        real(dp) :: clip(4, 3), ndc(3, 3), wpos(3, 3), wnrm(3, 3)
        type(vec3) :: wv, nv
        integer(int64) :: area2
        logical :: dbl, skip
        integer :: swapi
        real(dp) :: swapd
        integer(int64) :: swapi64

        g = 0
        do oi = 1, sc%n_objects
            if (.not. allocated(sc%objects(oi)%mesh%triangles)) cycle
            model_view = mat4_mult(sc%cam%view_matrix, models(oi))
            mvp = mat4_mult(sc%cam%proj_matrix, model_view)
            dbl = (trim(sc%objects(oi)%prim) == 'plane')
            do ti = 1, sc%objects(oi)%mesh%num_triangles
                tri = sc%objects(oi)%mesh%triangles(ti)
                g = g + 1
                ts%obj_id(g) = oi
                ts%alpha_mode(g) = sc%objects(oi)%pbr%alpha_mode
                ts%mat_id(g) = tri%material_id
                if (sc%objects(oi)%has_shader) then
                    ts%shader_id(g) = 1
                else
                    ts%shader_id(g) = 0
                end if
                if (sc%objects(oi)%mat%use_tri_color) then
                    ts%col(:, g) = real(tri%color, real32) / 255.0_real32
                else
                    ts%col(:, g) = real(sc%objects(oi)%mat%color, real32)
                end if
                ts%backface(g) = .false.
                ts%bb(:, g) = [1, 0, 1, 0]  ! empty until proven visible

                skip = .false.
                do k = 1, 3
                    wv = mat4_transform_vec3(models(oi), tri%v(k), .true.)
                    wpos(:, k) = [wv%x, wv%y, wv%z]
                    if (tri%smooth) then
                        nv = vec3_normalize(mat4_transform_vec3( &
                            models(oi), tri%vn(k), .false.))
                    else
                        nv = vec3_normalize(mat4_transform_vec3( &
                            models(oi), tri%normal, .false.))
                    end if
                    wnrm(:, k) = [nv%x, nv%y, nv%z]
                    ! Homogeneous clip position, mirroring renderer_3d.
                    clip(1, k) = mvp%m(1, 1) * tri%v(k)%x + mvp%m(1, 2) * tri%v(k)%y &
                               + mvp%m(1, 3) * tri%v(k)%z + mvp%m(1, 4)
                    clip(2, k) = mvp%m(2, 1) * tri%v(k)%x + mvp%m(2, 2) * tri%v(k)%y &
                               + mvp%m(2, 3) * tri%v(k)%z + mvp%m(2, 4)
                    clip(3, k) = mvp%m(3, 1) * tri%v(k)%x + mvp%m(3, 2) * tri%v(k)%y &
                               + mvp%m(3, 3) * tri%v(k)%z + mvp%m(3, 4)
                    clip(4, k) = mvp%m(4, 1) * tri%v(k)%x + mvp%m(4, 2) * tri%v(k)%y &
                               + mvp%m(4, 3) * tri%v(k)%z + mvp%m(4, 4)
                    if (clip(4, k) <= 1.0e-9_dp) skip = .true.
                end do
                if (skip) cycle
                do k = 1, 3
                    ndc(:, k) = clip(1:3, k) / clip(4, k)
                    if (abs(ndc(1, k)) > 4.0_dp .or. abs(ndc(2, k)) > 4.0_dp &
                        .or. abs(ndc(3, k)) > 4.0_dp) skip = .true.
                    ts%invw(k, g) = 1.0_dp / clip(4, k)
                    ts%wp(:, k, g) = wpos(:, k)
                    ts%nrm(:, k, g) = wnrm(:, k)
                    ts%uv(:, k, g) = tri%uv(:, k)
                    ! Screen: x right, y DOWN (row 1 = top), 28.4 fixed.
                    ts%fx(k, g) = nint(((ndc(1, k) + 1.0_dp) * 0.5_dp &
                        * real(width, dp)) * real(FP_ONE, dp), int64)
                    ts%fy(k, g) = nint(((1.0_dp - (ndc(2, k) + 1.0_dp) &
                        * 0.5_dp) * real(height, dp)) * real(FP_ONE, dp), int64)
                end do
                if (skip) cycle
                ! Signed doubled area in fixed point (y-down screen).
                area2 = (ts%fx(2, g) - ts%fx(1, g)) &
                    * (ts%fy(3, g) - ts%fy(1, g)) &
                    - (ts%fy(2, g) - ts%fy(1, g)) &
                    * (ts%fx(3, g) - ts%fx(1, g))
                if (area2 == 0_int64) cycle
                if (area2 < 0_int64) then
                    if (.not. dbl) cycle  ! backface culled
                    ! Re-wind: swap corners 2 and 3 everywhere.
                    ts%backface(g) = .true.
                    swapi64 = ts%fx(2, g); ts%fx(2, g) = ts%fx(3, g); ts%fx(3, g) = swapi64
                    swapi64 = ts%fy(2, g); ts%fy(2, g) = ts%fy(3, g); ts%fy(3, g) = swapi64
                    do swapi = 1, 3
                        swapd = ts%wp(swapi, 2, g); ts%wp(swapi, 2, g) = ts%wp(swapi, 3, g); ts%wp(swapi, 3, g) = swapd
                        swapd = ts%nrm(swapi, 2, g); ts%nrm(swapi, 2, g) = ts%nrm(swapi, 3, g); ts%nrm(swapi, 3, g) = swapd
                    end do
                    do swapi = 1, 2
                        swapd = ts%uv(swapi, 2, g); ts%uv(swapi, 2, g) = ts%uv(swapi, 3, g); ts%uv(swapi, 3, g) = swapd
                    end do
                    swapd = ts%invw(2, g); ts%invw(2, g) = ts%invw(3, g); ts%invw(3, g) = swapd
                end if
                ts%bb(1, g) = max(1, int(minval(ts%fx(:, g)) / FP_ONE) + 1)
                ts%bb(2, g) = min(width, int(maxval(ts%fx(:, g)) / FP_ONE) + 1)
                ts%bb(3, g) = max(1, int(minval(ts%fy(:, g)) / FP_ONE) + 1)
                ts%bb(4, g) = min(height, int(maxval(ts%fy(:, g)) / FP_ONE) + 1)
            end do
        end do
    end subroutine vertex_stage

    pure function edge_fn(ax, ay, bx, by, px, py) result(e)
        integer(int64), intent(in) :: ax, ay, bx, by, px, py
        integer(int64) :: e
        e = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    end function edge_fn

    ! Top-left test for directed edge a -> b (y-down screen space).
    ! Antisymmetric by construction: exactly one of (a->b, b->a) is
    ! top-left, which is what makes shared edges cover exactly once.
    pure function is_top_left(ax, ay, bx, by) result(tl)
        integer(int64), intent(in) :: ax, ay, bx, by
        logical :: tl
        tl = (by < ay) .or. (by == ay .and. bx > ax)
    end function is_top_left

    ! Pass 1: tile-binned rasterisation into the visibility buffer.
    subroutine rasterize_vis(vb, ts)
        type(v3_buffer), intent(inout) :: vb
        type(tri_store), intent(in) :: ts
        integer :: ntx, nty, tix, tiy, tile, g, x, y
        integer :: x0, x1, y0, y1
        integer(int64) :: e0, e1, e2, area, pxf, pyf
        real(dp) :: l0, l1, l2, invw_i
        logical :: tl0, tl1, tl2, inside

        ntx = (vb%width + V3_TILE - 1) / V3_TILE
        nty = (vb%height + V3_TILE - 1) / V3_TILE
        !$omp parallel do schedule(static) private(tile, tix, tiy, g, x, y, &
        !$omp& x0, x1, y0, y1, e0, e1, e2, area, pxf, pyf, l0, l1, l2, &
        !$omp& invw_i, tl0, tl1, tl2, inside)
        do tile = 0, ntx * nty - 1
            tix = mod(tile, ntx)
            tiy = tile / ntx
            x0 = tix * V3_TILE + 1
            x1 = min(vb%width, x0 + V3_TILE - 1)
            y0 = tiy * V3_TILE + 1
            y1 = min(vb%height, y0 + V3_TILE - 1)
            do g = 1, ts%n
                if (ts%bb(2, g) < ts%bb(1, g)) cycle  ! culled / skipped
                ! Phase 4: transparent (blend) triangles are NOT
                ! part of the opaque visibility pass; blend_pass
                ! draws them afterwards, sorted back-to-front.
                if (ts%alpha_mode(g) == 2) cycle
                if (ts%bb(1, g) > x1 .or. ts%bb(2, g) < x0) cycle
                if (ts%bb(3, g) > y1 .or. ts%bb(4, g) < y0) cycle
                area = edge_fn(ts%fx(1, g), ts%fy(1, g), &
                               ts%fx(2, g), ts%fy(2, g), &
                               ts%fx(3, g), ts%fy(3, g))
                if (area <= 0_int64) cycle
                tl0 = is_top_left(ts%fx(2, g), ts%fy(2, g), ts%fx(3, g), ts%fy(3, g))
                tl1 = is_top_left(ts%fx(3, g), ts%fy(3, g), ts%fx(1, g), ts%fy(1, g))
                tl2 = is_top_left(ts%fx(1, g), ts%fy(1, g), ts%fx(2, g), ts%fy(2, g))
                do y = max(y0, ts%bb(3, g)), min(y1, ts%bb(4, g))
                    pyf = int(y - 1, int64) * FP_ONE + FP_ONE / 2_int64
                    do x = max(x0, ts%bb(1, g)), min(x1, ts%bb(2, g))
                        pxf = int(x - 1, int64) * FP_ONE + FP_ONE / 2_int64
                        e0 = edge_fn(ts%fx(2, g), ts%fy(2, g), &
                                     ts%fx(3, g), ts%fy(3, g), pxf, pyf)
                        e1 = edge_fn(ts%fx(3, g), ts%fy(3, g), &
                                     ts%fx(1, g), ts%fy(1, g), pxf, pyf)
                        e2 = edge_fn(ts%fx(1, g), ts%fy(1, g), &
                                     ts%fx(2, g), ts%fy(2, g), pxf, pyf)
                        inside = (e0 > 0_int64 .or. (e0 == 0_int64 .and. tl0)) &
                           .and. (e1 > 0_int64 .or. (e1 == 0_int64 .and. tl1)) &
                           .and. (e2 > 0_int64 .or. (e2 == 0_int64 .and. tl2))
                        if (.not. inside) cycle
                        vb%cover(x, y) = vb%cover(x, y) + 1
                        l0 = real(e0, dp) / real(area, dp)
                        l1 = real(e1, dp) / real(area, dp)
                        l2 = real(e2, dp) / real(area, dp)
                        invw_i = l0 * ts%invw(1, g) + l1 * ts%invw(2, g) &
                               + l2 * ts%invw(3, g)
                        if (real(invw_i, real32) > vb%depth(x, y)) then
                            vb%depth(x, y) = real(invw_i, real32)
                            vb%vis_tri(x, y) = int(g, int32)
                            vb%lam(1, x, y) = real(l1, real32)
                            vb%lam(2, x, y) = real(l2, real32)
                        end if
                    end do
                end do
            end do
        end do
        !$omp end parallel do
    end subroutine rasterize_vis

    ! Reconstruct the fragment input for triangle g at a pixel
    ! from barycentric lambdas, with perspective-correct
    ! interpolation.  Derivatives are zeroed; callers that have
    ! same-triangle neighbours (the opaque shade pass) fill them.
    subroutine build_fin(ts, g, lam, fin)
        type(tri_store), intent(in) :: ts
        integer, intent(in) :: g
        real(dp), intent(in) :: lam(3)
        type(frag_in), intent(out) :: fin
        integer :: k
        do k = 1, 3
            fin%wp(k) = real(v3_perspective_interp( &
                lam, ts%wp(k, :, g), ts%invw(:, g)), real32)
            fin%nrm(k) = real(v3_perspective_interp( &
                lam, ts%nrm(k, :, g), ts%invw(:, g)), real32)
        end do
        do k = 1, 2
            fin%uv(k) = real(v3_perspective_interp( &
                lam, ts%uv(k, :, g), ts%invw(:, g)), real32)
        end do
        fin%col = ts%col(:, g)
        fin%mat_id = ts%mat_id(g)
        fin%obj_id = ts%obj_id(g)
        fin%shader_id = ts%shader_id(g)
        fin%backface = ts%backface(g)
        fin%wp_dx = 0.0_real32
        fin%wp_dy = 0.0_real32
        fin%uv_dx = 0.0_real32
        fin%uv_dy = 0.0_real32
    end subroutine build_fin

    ! Pixel-level coverage of triangle g at pixel (x, y): the same
    ! edge functions + top-left fill rule as rasterize_vis.
    ! On cover, returns the barycentrics and interpolated 1/w.
    subroutine pixel_cover(ts, g, x, y, covered, lam, invw_i)
        type(tri_store), intent(in) :: ts
        integer, intent(in) :: g, x, y
        logical, intent(out) :: covered
        real(dp), intent(out) :: lam(3), invw_i
        integer(int64) :: e0, e1, e2, area, pxf, pyf
        logical :: tl0, tl1, tl2
        covered = .false.
        lam = 0.0_dp
        invw_i = 0.0_dp
        if (ts%bb(2, g) < ts%bb(1, g)) return
        if (x < ts%bb(1, g) .or. x > ts%bb(2, g)) return
        if (y < ts%bb(3, g) .or. y > ts%bb(4, g)) return
        area = edge_fn(ts%fx(1, g), ts%fy(1, g), ts%fx(2, g), &
                       ts%fy(2, g), ts%fx(3, g), ts%fy(3, g))
        if (area <= 0_int64) return
        pxf = int(x - 1, int64) * FP_ONE + FP_ONE / 2_int64
        pyf = int(y - 1, int64) * FP_ONE + FP_ONE / 2_int64
        e0 = edge_fn(ts%fx(2, g), ts%fy(2, g), ts%fx(3, g), &
                     ts%fy(3, g), pxf, pyf)
        e1 = edge_fn(ts%fx(3, g), ts%fy(3, g), ts%fx(1, g), &
                     ts%fy(1, g), pxf, pyf)
        e2 = edge_fn(ts%fx(1, g), ts%fy(1, g), ts%fx(2, g), &
                     ts%fy(2, g), pxf, pyf)
        tl0 = is_top_left(ts%fx(2, g), ts%fy(2, g), ts%fx(3, g), &
                          ts%fy(3, g))
        tl1 = is_top_left(ts%fx(3, g), ts%fy(3, g), ts%fx(1, g), &
                          ts%fy(1, g))
        tl2 = is_top_left(ts%fx(1, g), ts%fy(1, g), ts%fx(2, g), &
                          ts%fy(2, g))
        covered = (e0 > 0_int64 .or. (e0 == 0_int64 .and. tl0)) &
            .and. (e1 > 0_int64 .or. (e1 == 0_int64 .and. tl1)) &
            .and. (e2 > 0_int64 .or. (e2 == 0_int64 .and. tl2))
        if (.not. covered) return
        lam(1) = real(e0, dp) / real(area, dp)
        lam(2) = real(e1, dp) / real(area, dp)
        lam(3) = real(e2, dp) / real(area, dp)
        invw_i = lam(1) * ts%invw(1, g) + lam(2) * ts%invw(2, g) &
               + lam(3) * ts%invw(3, g)
    end subroutine pixel_cover

    ! Pass 2: one walk over pixels; reconstruct the fragment input
    ! from the winning triangle with perspective-correct
    ! interpolation and shade it through fragment_v3_3d.
    !
    ! Phase 4 changes:
    !  * Reconstruction happens in a FIRST walk that fills the
    !    pos_dbg / uv_dbg buffers for every covered pixel; the
    !    shade walk then computes the screen-space derivatives
    !    (fin%wp_dx etc.) by finite differences against the
    !    right / bottom neighbour when that neighbour's winning
    !    triangle is the same (vis_tri equal), else zero.
    !  * Shading goes through frag_shade_a.  On a mask DISCARD the
    !    pixel is re-shaded with the next covering triangle: the
    !    covering triangle (per pixel_cover) with the largest 1/w
    !    strictly below the discarded hit's, repeated up to 8
    !    layers; if none covers, the pixel falls back to the
    !    background.  Cost: only discarded pixels pay the
    !    O(triangles) search; all other pixels are untouched.
    !    Re-shaded fragments carry zero derivatives (their
    !    same-triangle neighbours are not tracked), so their
    !    texture LOD is the base level and normal maps fall back
    !    to the geometric normal there -- documented trade-off.
    !  * vis_tri / depth / lam keep describing the FIRST (nearest)
    !    hit even when a deeper layer was shaded, so downstream
    !    consumers (quantize background test, SSAA hooks) keep
    !    their Phase 2/3 meaning; %shaded marks the pixel painted.
    subroutine shade_pass(vb, sc, ts)
        type(v3_buffer), intent(inout) :: vb
        type(Scene), intent(in) :: sc
        type(tri_store), intent(in) :: ts
        integer :: x, y, g
        real(dp) :: lam(3)
        type(frag_in) :: fin
        real(real32) :: rgb(3), alpha
        logical :: discard

        ! Walk 1: reconstruct wp/uv for every covered pixel.
        !$omp parallel do schedule(static) private(x, y, g, lam, fin, rgb)
        do y = 1, vb%height
            do x = 1, vb%width
                g = int(vb%vis_tri(x, y))
                if (g <= 0) cycle
                lam(2) = real(vb%lam(1, x, y), dp)
                lam(3) = real(vb%lam(2, x, y), dp)
                lam(1) = 1.0_dp - lam(2) - lam(3)
                call build_fin(ts, g, lam, fin)
                vb%uv_dbg(:, x, y) = fin%uv
                vb%pos_dbg(:, x, y) = fin%wp
            end do
        end do
        !$omp end parallel do

        ! Walk 2: derivatives + shade (with mask-discard re-shade).
        !$omp parallel do schedule(static) private(x, y, g, lam, fin, &
        !$omp& rgb, alpha, discard)
        do y = 1, vb%height
            do x = 1, vb%width
                g = int(vb%vis_tri(x, y))
                if (g <= 0) cycle
                lam(2) = real(vb%lam(1, x, y), dp)
                lam(3) = real(vb%lam(2, x, y), dp)
                lam(1) = 1.0_dp - lam(2) - lam(3)
                call build_fin(ts, g, lam, fin)
                if (x < vb%width) then
                    if (vb%vis_tri(x + 1, y) == vb%vis_tri(x, y)) then
                        fin%wp_dx = vb%pos_dbg(:, x + 1, y) - fin%wp
                        fin%uv_dx = vb%uv_dbg(:, x + 1, y) - fin%uv
                    end if
                end if
                if (y < vb%height) then
                    if (vb%vis_tri(x, y + 1) == vb%vis_tri(x, y)) then
                        fin%wp_dy = vb%pos_dbg(:, x, y + 1) - fin%wp
                        fin%uv_dy = vb%uv_dbg(:, x, y + 1) - fin%uv
                    end if
                end if
                call frag_shade_a(fin, sc, rgb, discard, alpha)
                if (discard) then
                    call reshade_below(vb, sc, ts, x, y, rgb, discard)
                end if
                if (discard) then
                    ! No layer below survived: background.
                    vb%rgb(1, x, y) = real(sc%bg(1), real32) &
                        / 255.0_real32
                    vb%rgb(2, x, y) = real(sc%bg(2), real32) &
                        / 255.0_real32
                    vb%rgb(3, x, y) = real(sc%bg(3), real32) &
                        / 255.0_real32
                else
                    vb%rgb(:, x, y) = rgb
                    vb%shaded(x, y) = 1
                end if
            end do
        end do
        !$omp end parallel do
    end subroutine shade_pass

    ! Mask-discard re-shade: starting from the pixel's winning
    ! (discarded) hit, repeatedly find the covering opaque
    ! triangle with the largest 1/w strictly below the current
    ! layer's and shade it, up to 8 layers.  On exit discard is
    ! .false. and rgb holds the surviving layer's colour, or
    ! discard stays .true. when no layer below survives (the
    ! caller then writes the background).  Only called for
    ! discarded pixels, so its O(8 * triangles) cost is paid
    ! nowhere else.
    subroutine reshade_below(vb, sc, ts, x, y, rgb, discard)
        type(v3_buffer), intent(in) :: vb
        type(Scene), intent(in) :: sc
        type(tri_store), intent(in) :: ts
        integer, intent(in) :: x, y
        real(real32), intent(out) :: rgb(3)
        logical, intent(inout) :: discard
        integer :: layer, g2, best_g
        real(dp) :: lam(3), invw_i, cur_invw, best_invw
        logical :: covered
        type(frag_in) :: fin
        real(real32) :: alpha

        cur_invw = real(vb%depth(x, y), dp)
        do layer = 1, 8
            best_g = 0
            best_invw = 0.0_dp
            do g2 = 1, ts%n
                if (ts%alpha_mode(g2) == 2) cycle  ! opaque layers only
                call pixel_cover(ts, g2, x, y, covered, lam, invw_i)
                if (.not. covered) cycle
                if (invw_i < cur_invw - 1.0e-12_dp .and. &
                    invw_i > best_invw) then
                    best_g = g2
                    best_invw = invw_i
                end if
            end do
            if (best_g == 0) return  ! nothing below: discard stands
            call pixel_cover(ts, best_g, x, y, covered, lam, invw_i)
            call build_fin(ts, best_g, lam, fin)
            call frag_shade_a(fin, sc, rgb, discard, alpha)
            if (.not. discard) return
            cur_invw = best_invw
        end do
    end subroutine reshade_below

    ! Phase 4 transparent pass (alpha_mode == 2 objects).
    !
    ! Runs AFTER the opaque shade pass.  Transparent triangles
    ! are gathered and sorted back-to-front by their centroid
    ! depth key (mean corner 1/w; SMALLER 1/w = farther, drawn
    ! first).  Ties break on the global triangle index, so the
    ! order is total and deterministic.  Each covered pixel
    ! (pixel_cover: the same edge-function fill rule) is
    ! depth-tested against the OPAQUE 1/w buffer only -- the
    ! fragment is drawn iff it lies in front of the opaque
    ! surface (invw > depth) -- shaded via frag_shade_a
    ! (discard honoured: skipped), and composited in LINEAR
    ! space: rgb = src.rgb * src.a + dst.rgb * (1 - src.a).
    ! No depth writes.
    !
    ! Threading choice: this pass is SINGLE-THREADED, on
    ! purpose.  Compositing is order-dependent, and per-pixel
    ! order is the global sort order; running it serially makes
    ! the result trivially thread-count invariant (the opaque
    ! passes keep their tile/row parallelism).  Transparent
    ! geometry is a small fraction of a typical scene; the cost
    ! is documented rather than optimised away.
    subroutine blend_pass(vb, sc, ts)
        type(v3_buffer), intent(inout) :: vb
        type(Scene), intent(in) :: sc
        type(tri_store), intent(in) :: ts
        integer, allocatable :: order(:)
        real(dp), allocatable :: key(:)
        integer :: n_tr, i, j, g, x, y, tmpi
        real(dp) :: lam(3), invw_i, tmpk
        logical :: covered, discard
        type(frag_in) :: fin
        real(real32) :: rgb(3), alpha

        n_tr = 0
        do g = 1, ts%n
            if (ts%alpha_mode(g) == 2 .and. &
                ts%bb(2, g) >= ts%bb(1, g)) n_tr = n_tr + 1
        end do
        if (n_tr == 0) return
        allocate(order(n_tr), key(n_tr))
        i = 0
        do g = 1, ts%n
            if (ts%alpha_mode(g) /= 2) cycle
            if (ts%bb(2, g) < ts%bb(1, g)) cycle
            i = i + 1
            order(i) = g
            key(i) = sum(ts%invw(:, g)) / 3.0_dp
        end do
        ! Insertion sort, ascending key (far = small 1/w first);
        ! ties on triangle index make the order total.
        do i = 2, n_tr
            tmpi = order(i)
            tmpk = key(i)
            j = i - 1
            do while (j >= 1)
                if (key(j) < tmpk) exit
                if (key(j) == tmpk .and. order(j) < tmpi) exit
                order(j + 1) = order(j)
                key(j + 1) = key(j)
                j = j - 1
            end do
            order(j + 1) = tmpi
            key(j + 1) = tmpk
        end do

        do i = 1, n_tr
            g = order(i)
            do y = ts%bb(3, g), ts%bb(4, g)
                do x = ts%bb(1, g), ts%bb(2, g)
                    call pixel_cover(ts, g, x, y, covered, lam, &
                                     invw_i)
                    if (.not. covered) cycle
                    ! In front of the opaque surface only.
                    if (real(invw_i, real32) <= vb%depth(x, y)) cycle
                    call build_fin(ts, g, lam, fin)
                    call frag_shade_a(fin, sc, rgb, discard, alpha)
                    if (discard) cycle
                    vb%rgb(:, x, y) = rgb * alpha &
                        + vb%rgb(:, x, y) * (1.0_real32 - alpha)
                    vb%shaded(x, y) = 1
                end do
            end do
        end do
        deallocate(order, key)
    end subroutine blend_pass

end module renderer_v3_3d
