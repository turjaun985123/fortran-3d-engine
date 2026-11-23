! shadow_v3.f90 -- Forge3D v3.0 Phase 3: PER-LIGHT shadow maps for
! the v3 renderer (module shadow_v3_3d).
!
! This replaces the legacy single-map scheme (src/shadow.f90, frozen
! by ADR-1 and NOT used here) in which ONE shadow factor -- sampled
! from the key light's 60-degree perspective map with a constant
! 0.002 bias -- was applied to every light (finding L1), and whose
! directional frustum was not fitted to the scene (finding L2).
! Here every shadow-casting light in Scene%lights gets its own
! depth map, built once per frame by shadow_v3_build, and
! shadow_v3_factor(light_index, ...) answers visibility for THAT
! light only, so two lights shadow independently.
!
! API (pinned by the Phase 3 plan; the fragment stage codes against
! exactly this):
!   subroutine shadow_v3_build(sc, models)
!   function   shadow_v3_factor(light_index, wp, nrm) result(f)
!              ! real(real32) in [0,1]; wp/nrm are real32 (3) arrays
!   subroutine shadow_v3_clear()
!   integer, public :: shadow_v3_map_size
!
! Thread-safety: build is single-threaded and finishes before the
! shade pass; factor is pure read-only over the module state (no
! mutation, no allocation), so it is safe inside the OpenMP shade
! loop.  All state lives in this module; clear() frees everything.
!
! Projections (depth = view-space distance along the light's view
! axis, stored as real32; LARGER stored depth = FARTHER from the
! light; a receiver is lit iff receiver_depth <= stored + bias):
!   * Directional: ORTHOGRAPHIC.  The view looks along the light
!     direction from eye = centre - dir * (radius + 10), where
!     centre/radius come from the world AABB of all scene triangles
!     (transformed by models(:)).  The ortho box [left,right] x
!     [bottom,top] x [near,far] is fitted to the 8 AABB corners in
!     light view space, padded by 2% + 0.1 world units laterally and
!     0.05*radius + 0.5 in depth, so the whole scene is inside.
!     Texel snapping of the ortho origin is NOT done (documented
!     skip): the fitted box is recomputed from the same bounds each
!     build, so a static scene gives a static map; animated scenes
!     may shimmer by sub-texel amounts, accepted for Phase 3.
!     Depth interpolation is affine, which is EXACT under an ortho
!     projection.
!   * Spot: PERSPECTIVE from the light position towards
!     pos + spot_dir, full FOV = 2 * angle_deg (angle_deg is the
!     half-angle lighting_3d's spot_factor compares against),
!     aspect 1, near = 0.1, far = light%distance when > 0, else
!     1.1 * (distance from the light to the farthest AABB corner)
!     + 1.  Depth is perspective-correct: the rasteriser
!     interpolates 1/w and the stored depth is 1/(interpolated
!     1/w), exactly as the v3 main pass reconstructs attributes.
!   * Point: CUBE map -- 6 perspective faces, 90-degree FOV
!     (tan(half) = 1), near/far as for spot, stored as 6 maps.
!     Face order: 0:+X 1:-X 2:+Y 3:-Y 4:+Z 5:-Z (index = face+1 in
!     the storage array).  factor() selects the face by the
!     dominant axis of (wp - light_pos).  Face ups: +X/-X/+Z/-Z use
!     +Y; +Y uses -Z; -Y uses +Z (avoids look_at degeneracy).
!   Perspective triangles are clipped in view space against the
!   near plane (one Sutherland-Hodgman step, fan retriangulation)
!   before projection, so a caster crossing the near plane cannot
!   flip through w < 0.  No other clipping is needed: the
!   rasteriser clamps its bounding box to the map and the edge
!   functions are evaluated in continuous map space, so triangles
!   extending past the map edge rasterise correctly.
!   The depth rasteriser draws ALL faces (no winding cull): for a
!   closed caster the nearest surface along the light ray is the
!   occluder, whichever way its triangles wind.
!
! Bias (no magic constants; everything derives from the texel size
! at the receiver):
!   texel = world size of one shadow texel at the receiver:
!           ortho: (right - left) / map_size
!           persp: 2 * depth * tan(half_fov) / map_size
!   Normal offset: the sample position is moved along the
!   normalised receiver normal by exactly 1 texel:
!           wp' = wp + n_hat * texel
!   Slope-scaled depth bias, added to the stored depth:
!           bias = texel * (0.5 + slope), capped at 6 * texel, with
!           slope = sqrt(1 - ndl^2) / max(ndl, 0.25),
!           ndl = |dot(n_hat, L)|, L = unit direction TO the light.
!   A face-on receiver (ndl = 1) gets bias = 0.5 texel; a grazing
!   receiver gets up to the 6-texel cap.  (The legacy constant was
!   0.002 NDC units regardless of map size or slope.)
!
! PCF: shadow_mode 1 (hard) forces kernel radius 0 (single tap)
! regardless of sc%shadow_pcf.  shadow_mode 2 (soft) uses radius
! r = clamp(sc%shadow_pcf, 0, 8): the (2r+1)^2 taps on the regular
! texel grid centred on the receiver's texel are each tested
! binarily (same bias) and averaged.  Tap indices clamp to the map
! edge.  A receiver whose projection falls outside the map
! (NDC outside [-1,1]^2, or depth outside [near,far]) is FULLY LIT
! (factor 1): in particular a spot receiver outside the cone is
! unaffected by that light's shadow map -- documented rule, the
! cone falloff itself is lighting_3d's spot_factor, not ours.
!
! Memory: one real32 per texel per face.  At the default 1024, a
! 3-light scene of directional + spot + point costs
! (1 + 1 + 6) * 1024^2 * 4 B = 33,554,432 B = 32 MiB.
! Allocation is persistent: build() reuses the existing maps when
! the shape (light count, per-light face count, map size) is
! unchanged and only rewrites their contents; a shape change (or
! clear()) frees and reallocates.  Repeated builds therefore leak
! nothing.
module shadow_v3_3d
    use, intrinsic :: iso_fortran_env, only: real32
    use math_3d
    use mesh_3d, only: Triangle
    use scene_3d, only: Scene
    use lighting_3d, only: Light3
    implicit none
    private
    public :: shadow_v3_build, shadow_v3_factor, shadow_v3_clear
    public :: shadow_v3_map_size

    integer :: shadow_v3_map_size = 0  ! public via the public list above

    real(dp), parameter :: NO_DEPTH = 1.0e30_dp
    integer, parameter :: MAX_PCF_RADIUS = 8

    type :: shadow_face
        type(mat4) :: view                 ! world -> light view
        logical :: persp = .false.
        real(dp) :: left = -1.0_dp, right = 1.0_dp
        real(dp) :: bottom = -1.0_dp, top = 1.0_dp
        real(dp) :: near_d = 0.1_dp, far_d = 100.0_dp
        real(dp) :: tan_half = 1.0_dp      ! perspective only
        real(real32), allocatable :: depth(:, :)  ! (size, size)
    end type shadow_face

    type :: shadow_light
        integer :: kind = 0                ! 0 dir, 1 point, 2 spot
        integer :: nfaces = 0              ! 1 (dir/spot) or 6 (point)
        logical :: casts = .false.
        type(vec3) :: pos = vec3(0.0_dp, 0.0_dp, 0.0_dp)
        type(vec3) :: dir = vec3(0.0_dp, -1.0_dp, 0.0_dp)
        type(shadow_face) :: faces(6)
    end type shadow_light

    type(shadow_light), allocatable, target :: g_lights(:)
    integer :: g_nlights = 0
    integer :: g_mode = 0                  ! scene shadow_mode at build
    integer :: g_pcf = 1                   ! scene shadow_pcf at build
    logical :: g_built = .false.

contains

    ! ------------------------------------------------------------------
    ! Public API
    ! ------------------------------------------------------------------

    subroutine shadow_v3_clear()
        integer :: i, f
        if (allocated(g_lights)) then
            do i = 1, size(g_lights)
                do f = 1, 6
                    if (allocated(g_lights(i)%faces(f)%depth)) &
                        deallocate(g_lights(i)%faces(f)%depth)
                end do
            end do
            deallocate(g_lights)
        end if
        g_nlights = 0
        g_mode = 0
        g_built = .false.
        shadow_v3_map_size = 0
    end subroutine shadow_v3_clear

    subroutine shadow_v3_build(sc, models)
        type(Scene), intent(in) :: sc
        type(mat4), intent(in) :: models(:)

        type(Light3), allocatable :: eff(:)
        integer :: nlights, sz, i, f, old_sz
        logical :: same_shape
        real(dp) :: bmin(3), bmax(3), centre(3), radius
        logical :: have_geo

        g_mode = sc%shadow_mode
        g_pcf = sc%shadow_pcf
        g_built = .true.
        if (sc%shadow_mode == 0) then
            ! Build nothing; factor() short-circuits on g_mode == 0.
            call shadow_v3_clear()
            g_mode = 0
            g_built = .true.
            return
        end if

        old_sz = shadow_v3_map_size
        sz = sc%shadow_size
        if (sz <= 0) sz = 1024
        sz = min(4096, max(64, sz))
        shadow_v3_map_size = sz

        call effective_lights(sc, eff, nlights)

        ! Persistent allocation: reuse storage on a shape match.
        same_shape = allocated(g_lights) .and. g_nlights == nlights &
                     .and. old_sz == sz
        if (same_shape) then
            do i = 1, nlights
                if (g_lights(i)%nfaces /= faces_for(eff(i))) &
                    same_shape = .false.
            end do
        end if
        if (.not. same_shape) then
            call free_maps_only()
            if (allocated(g_lights)) deallocate(g_lights)
            allocate(g_lights(nlights))
            g_nlights = nlights
            do i = 1, nlights
                g_lights(i)%nfaces = faces_for(eff(i))
                do f = 1, g_lights(i)%nfaces
                    allocate(g_lights(i)%faces(f)%depth(sz, sz))
                end do
            end do
        end if

        ! Scene world bounds from the transformed triangles.
        call scene_bounds(sc, models, bmin, bmax, have_geo)
        if (have_geo) then
            centre = 0.5_dp * (bmin + bmax)
            radius = 0.5_dp * sqrt(sum((bmax - bmin) ** 2))
            radius = max(radius, 1.0_dp)
        else
            centre = 0.0_dp
            radius = 1.0_dp
        end if

        do i = 1, nlights
            call setup_light(g_lights(i), eff(i), centre, radius, &
                             bmin, bmax)
            do f = 1, g_lights(i)%nfaces
                g_lights(i)%faces(f)%depth = real(NO_DEPTH, real32)
                if (g_lights(i)%casts .and. have_geo) &
                    call rasterize_face(g_lights(i)%faces(f), sc, models)
            end do
        end do
        if (allocated(eff)) deallocate(eff)
    end subroutine shadow_v3_build

    function shadow_v3_factor(light_index, wp, nrm) result(fac)
        integer, intent(in) :: light_index
        real(real32), intent(in) :: wp(3), nrm(3)
        real(real32) :: fac

        type(shadow_light), pointer :: lt
        type(shadow_face), pointer :: fc
        integer :: face_idx, radius_pcf, dx, dy, tx, ty, lit, total
        real(dp) :: w(3), n(3), nl, ldir(3), ndl, d0, texel, slope
        real(dp) :: bias, v(3), ndc(2), cx, cy
        integer :: ccx, ccy

        fac = 1.0_real32
        if (.not. g_built .or. g_mode == 0) return
        if (.not. allocated(g_lights)) return
        if (light_index < 1 .or. light_index > g_nlights) return
        lt => g_lights(light_index)
        if (.not. lt%casts .or. lt%nfaces <= 0) return

        w = real(wp, dp)
        n = real(nrm, dp)
        nl = sqrt(sum(n * n))
        if (nl > 1.0e-12_dp) then
            n = n / nl
        else
            n = 0.0_dp
        end if

        ! Direction TO the light (for the slope term).
        if (lt%kind == 0) then
            ldir = [-lt%dir%x, -lt%dir%y, -lt%dir%z]
        else
            ldir = [lt%pos%x - w(1), lt%pos%y - w(2), lt%pos%z - w(3)]
        end if
        nl = sqrt(sum(ldir * ldir))
        if (nl > 1.0e-12_dp) ldir = ldir / nl
        ndl = abs(n(1) * ldir(1) + n(2) * ldir(2) + n(3) * ldir(3))
        if (nl <= 1.0e-12_dp) ndl = 1.0_dp

        face_idx = pick_face(lt, w)
        fc => lt%faces(face_idx)
        if (.not. allocated(fc%depth)) return

        ! Receiver depth / texel size at the UN-offset position.
        call project(fc, w, v, ndc, d0)
        if (d0 < fc%near_d .or. d0 > fc%far_d) return
        if (abs(ndc(1)) > 1.0_dp .or. abs(ndc(2)) > 1.0_dp) return
        if (fc%persp) then
            texel = 2.0_dp * d0 * fc%tan_half &
                    / real(shadow_v3_map_size, dp)
        else
            texel = (fc%right - fc%left) / real(shadow_v3_map_size, dp)
        end if
        texel = max(texel, 1.0e-9_dp)

        ! Normal offset (1 texel) + slope-scaled bias (see header).
        w = w + n * texel
        call project(fc, w, v, ndc, d0)
        if (d0 < fc%near_d .or. d0 > fc%far_d) return
        if (abs(ndc(1)) > 1.0_dp .or. abs(ndc(2)) > 1.0_dp) return
        slope = sqrt(max(0.0_dp, 1.0_dp - ndl * ndl)) &
                / max(ndl, 0.25_dp)
        bias = min(texel * (0.5_dp + slope), 6.0_dp * texel)

        ! Centre texel in centre-based float pixel coordinates.
        cx = (ndc(1) + 1.0_dp) * 0.5_dp &
             * real(shadow_v3_map_size, dp) - 0.5_dp
        cy = (1.0_dp - ndc(2)) * 0.5_dp &
             * real(shadow_v3_map_size, dp) - 0.5_dp
        ccx = nint(cx)
        ccy = nint(cy)

        if (g_mode == 1) then
            radius_pcf = 0
        else
            radius_pcf = min(MAX_PCF_RADIUS, max(0, g_pcf))
        end if
        lit = 0
        total = 0
        do dy = -radius_pcf, radius_pcf
            do dx = -radius_pcf, radius_pcf
                tx = min(shadow_v3_map_size, max(1, ccx + dx + 1))
                ty = min(shadow_v3_map_size, max(1, ccy + dy + 1))
                total = total + 1
                if (d0 <= real(fc%depth(tx, ty), dp) + bias) &
                    lit = lit + 1
            end do
        end do
        fac = real(real(lit, dp) / real(total, dp), real32)
    end function shadow_v3_factor

    ! ------------------------------------------------------------------
    ! Internal helpers
    ! ------------------------------------------------------------------

    subroutine free_maps_only()
        integer :: i, f
        if (.not. allocated(g_lights)) return
        do i = 1, size(g_lights)
            do f = 1, 6
                if (allocated(g_lights(i)%faces(f)%depth)) &
                    deallocate(g_lights(i)%faces(f)%depth)
            end do
        end do
    end subroutine free_maps_only

    pure function faces_for(lt) result(nf)
        type(Light3), intent(in) :: lt
        integer :: nf
        if (lt%kind == 1) then
            nf = 6
        else
            nf = 1
        end if
    end function faces_for

    ! The scene's effective LightSet, mirroring fragment_v3's rule:
    ! sc%lights as assembled by scene_load when present, else the
    ! single directional light from the legacy fields.
    subroutine effective_lights(sc, eff, n)
        type(Scene), intent(in) :: sc
        type(Light3), allocatable, intent(out) :: eff(:)
        integer, intent(out) :: n
        type(Light3) :: lt
        if (allocated(sc%lights%items)) then
            if (size(sc%lights%items) > 0) then
                n = size(sc%lights%items)
                allocate(eff(n))
                eff = sc%lights%items
                return
            end if
        end if
        n = 1
        allocate(eff(1))
        lt = Light3()
        lt%kind = 0
        lt%dir = sc%light_dir
        lt%spot_dir = sc%light_dir
        lt%color = sc%light_color
        lt%intensity = sc%light_intensity
        eff(1) = lt
    end subroutine effective_lights

    subroutine scene_bounds(sc, models, bmin, bmax, have)
        type(Scene), intent(in) :: sc
        type(mat4), intent(in) :: models(:)
        real(dp), intent(out) :: bmin(3), bmax(3)
        logical, intent(out) :: have
        integer :: oi, ti, k
        type(vec3) :: wv
        have = .false.
        bmin = NO_DEPTH
        bmax = -NO_DEPTH
        do oi = 1, sc%n_objects
            if (.not. allocated(sc%objects(oi)%mesh%triangles)) cycle
            do ti = 1, sc%objects(oi)%mesh%num_triangles
                do k = 1, 3
                    wv = mat4_transform_vec3(models(oi), &
                        sc%objects(oi)%mesh%triangles(ti)%v(k), .true.)
                    bmin = min(bmin, [wv%x, wv%y, wv%z])
                    bmax = max(bmax, [wv%x, wv%y, wv%z])
                    have = .true.
                end do
            end do
        end do
        if (.not. have) then
            bmin = -1.0_dp
            bmax = 1.0_dp
        end if
    end subroutine scene_bounds

    recursive subroutine setup_light(sl, lt, centre, radius, bmin, bmax)
        type(shadow_light), intent(inout) :: sl
        type(Light3), intent(in) :: lt
        real(dp), intent(in) :: centre(3), radius, bmin(3), bmax(3)
        type(vec3) :: dirn, eye, tgt, up
        real(dp) :: d, far_d, corn(3, 8), vv(3), dmin, dmax
        real(dp) :: lmin(2), lmax(2), pad_lat, pad_dep
        integer :: ci, f
        ! Cube face axes: dir index and up per face (+X,-X,+Y,-Y,+Z,-Z)
        real(dp) :: fdir(3, 6), fup(3, 6)

        sl%kind = lt%kind
        sl%pos = lt%pos
        sl%dir = lt%dir
        sl%casts = .true.

        fdir(:, 1) = [1.0_dp, 0.0_dp, 0.0_dp]
        fdir(:, 2) = [-1.0_dp, 0.0_dp, 0.0_dp]
        fdir(:, 3) = [0.0_dp, 1.0_dp, 0.0_dp]
        fdir(:, 4) = [0.0_dp, -1.0_dp, 0.0_dp]
        fdir(:, 5) = [0.0_dp, 0.0_dp, 1.0_dp]
        fdir(:, 6) = [0.0_dp, 0.0_dp, -1.0_dp]
        fup(:, 1) = [0.0_dp, 1.0_dp, 0.0_dp]
        fup(:, 2) = [0.0_dp, 1.0_dp, 0.0_dp]
        fup(:, 3) = [0.0_dp, 0.0_dp, -1.0_dp]
        fup(:, 4) = [0.0_dp, 0.0_dp, 1.0_dp]
        fup(:, 5) = [0.0_dp, 1.0_dp, 0.0_dp]
        fup(:, 6) = [0.0_dp, 1.0_dp, 0.0_dp]

        ! AABB corners for frustum fitting / far-plane distances.
        corn(:, 1) = [bmin(1), bmin(2), bmin(3)]
        corn(:, 2) = [bmax(1), bmin(2), bmin(3)]
        corn(:, 3) = [bmin(1), bmax(2), bmin(3)]
        corn(:, 4) = [bmax(1), bmax(2), bmin(3)]
        corn(:, 5) = [bmin(1), bmin(2), bmax(3)]
        corn(:, 6) = [bmax(1), bmin(2), bmax(3)]
        corn(:, 7) = [bmin(1), bmax(2), bmax(3)]
        corn(:, 8) = [bmax(1), bmax(2), bmax(3)]

        select case (lt%kind)
        case (0)  ! directional: fitted orthographic
            dirn = vec3_normalize(lt%dir)
            if (vec3_norm(dirn) <= 1.0e-12_dp) then
                sl%casts = .false.
                return
            end if
            sl%dir = dirn
            d = radius + 10.0_dp
            eye = vec3_create(centre(1) - dirn%x * d, &
                              centre(2) - dirn%y * d, &
                              centre(3) - dirn%z * d)
            tgt = vec3_create(centre(1), centre(2), centre(3))
            up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
            associate (fc => sl%faces(1))
                fc%persp = .false.
                fc%view = mat4_look_at(eye, tgt, up)
                lmin = NO_DEPTH
                lmax = -NO_DEPTH
                dmin = NO_DEPTH
                dmax = -NO_DEPTH
                do ci = 1, 8
                    vv = view_coords(fc%view, corn(:, ci))
                    lmin = min(lmin, vv(1:2))
                    lmax = max(lmax, vv(1:2))
                    dmin = min(dmin, -vv(3))
                    dmax = max(dmax, -vv(3))
                end do
                pad_lat = 0.02_dp * max(lmax(1) - lmin(1), &
                                        lmax(2) - lmin(2)) + 0.1_dp
                pad_dep = 0.05_dp * radius + 0.5_dp
                fc%left = lmin(1) - pad_lat
                fc%right = lmax(1) + pad_lat
                fc%bottom = lmin(2) - pad_lat
                fc%top = lmax(2) + pad_lat
                fc%near_d = max(0.01_dp, dmin - pad_dep)
                fc%far_d = dmax + pad_dep
            end associate
        case (2)  ! spot: perspective along spot_dir
            dirn = vec3_normalize(lt%spot_dir)
            if (vec3_norm(dirn) <= 1.0e-12_dp) then
                sl%casts = .false.
                return
            end if
            sl%dir = dirn
            far_d = persp_far(lt, corn)
            associate (fc => sl%faces(1))
                fc%persp = .true.
                fc%tan_half = tan(deg2rad(min(179.0_dp, &
                    max(1.0_dp, 2.0_dp * lt%angle_deg))) * 0.5_dp)
                fc%near_d = 0.1_dp
                fc%far_d = far_d
                tgt = vec3_add(lt%pos, dirn)
                fc%view = mat4_look_at(lt%pos, tgt, &
                    vec3_create(0.0_dp, 1.0_dp, 0.0_dp))
            end associate
        case (1)  ! point: 6-face cube, 90-degree perspective
            far_d = persp_far(lt, corn)
            do f = 1, 6
                associate (fc => sl%faces(f))
                    fc%persp = .true.
                    fc%tan_half = 1.0_dp
                    fc%near_d = 0.1_dp
                    fc%far_d = far_d
                    eye = lt%pos
                    tgt = vec3_create(lt%pos%x + fdir(1, f), &
                                      lt%pos%y + fdir(2, f), &
                                      lt%pos%z + fdir(3, f))
                    up = vec3_create(fup(1, f), fup(2, f), fup(3, f))
                    fc%view = mat4_look_at(eye, tgt, up)
                end associate
            end do
        case default  ! unknown kinds act directional (lighting_3d rule)
            sl%kind = 0
            block
                type(Light3) :: as_dir
                as_dir = lt
                as_dir%kind = 0
                call setup_light(sl, as_dir, centre, radius, bmin, bmax)
            end block
        end select
    end subroutine setup_light

    function persp_far(lt, corn) result(far_d)
        type(Light3), intent(in) :: lt
        real(dp), intent(in) :: corn(3, 8)
        real(dp) :: far_d
        integer :: ci
        real(dp) :: dd
        if (lt%distance > 0.0_dp) then
            far_d = lt%distance
        else
            far_d = 0.0_dp
            do ci = 1, 8
                dd = sqrt(sum((corn(:, ci) &
                        - [lt%pos%x, lt%pos%y, lt%pos%z]) ** 2))
                far_d = max(far_d, dd)
            end do
            far_d = far_d * 1.1_dp + 1.0_dp
        end if
        far_d = max(far_d, 1.0_dp)
    end function persp_far

    pure function view_coords(view, w) result(v)
        type(mat4), intent(in) :: view
        real(dp), intent(in) :: w(3)
        real(dp) :: v(3)
        v(1) = view%m(1, 1) * w(1) + view%m(1, 2) * w(2) &
             + view%m(1, 3) * w(3) + view%m(1, 4)
        v(2) = view%m(2, 1) * w(1) + view%m(2, 2) * w(2) &
             + view%m(2, 3) * w(3) + view%m(2, 4)
        v(3) = view%m(3, 1) * w(1) + view%m(3, 2) * w(2) &
             + view%m(3, 3) * w(3) + view%m(3, 4)
    end function view_coords

    ! Project a world point through a face: view coords v, NDC xy,
    ! and view depth d = -v(3).
    subroutine project(fc, w, v, ndc, d)
        type(shadow_face), intent(in) :: fc
        real(dp), intent(in) :: w(3)
        real(dp), intent(out) :: v(3), ndc(2), d
        v = view_coords(fc%view, w)
        d = -v(3)
        if (fc%persp) then
            if (abs(d) > 1.0e-12_dp) then
                ndc(1) = v(1) / (d * fc%tan_half)
                ndc(2) = v(2) / (d * fc%tan_half)
            else
                ndc = 2.0_dp  ! behind the eye: outside by construction
            end if
        else
            ndc(1) = 2.0_dp * (v(1) - fc%left) / (fc%right - fc%left) &
                     - 1.0_dp
            ndc(2) = 2.0_dp * (v(2) - fc%bottom) / (fc%top - fc%bottom) &
                     - 1.0_dp
        end if
    end subroutine project

    pure function pick_face(lt, w) result(fi)
        type(shadow_light), intent(in) :: lt
        real(dp), intent(in) :: w(3)
        integer :: fi
        real(dp) :: d(3)
        fi = 1
        if (lt%kind /= 1) return
        d = [w(1) - lt%pos%x, w(2) - lt%pos%y, w(3) - lt%pos%z]
        if (abs(d(1)) >= abs(d(2)) .and. abs(d(1)) >= abs(d(3))) then
            fi = merge(1, 2, d(1) >= 0.0_dp)
        else if (abs(d(2)) >= abs(d(3))) then
            fi = merge(3, 4, d(2) >= 0.0_dp)
        else
            fi = merge(5, 6, d(3) >= 0.0_dp)
        end if
    end function pick_face

    ! ------------------------------------------------------------------
    ! Depth rasteriser (own, small; renderer_v3 internals are not
    ! public and are not called).  All faces are drawn; the nearest
    ! depth wins.
    ! ------------------------------------------------------------------

    subroutine rasterize_face(fc, sc, models)
        type(shadow_face), intent(inout) :: fc
        type(Scene), intent(in) :: sc
        type(mat4), intent(in) :: models(:)
        integer :: oi, ti, k
        type(vec3) :: wv
        real(dp) :: vv(3, 3)
        do oi = 1, sc%n_objects
            if (.not. allocated(sc%objects(oi)%mesh%triangles)) cycle
            do ti = 1, sc%objects(oi)%mesh%num_triangles
                do k = 1, 3
                    wv = mat4_transform_vec3(models(oi), &
                        sc%objects(oi)%mesh%triangles(ti)%v(k), .true.)
                    vv(:, k) = view_coords(fc%view, [wv%x, wv%y, wv%z])
                end do
                if (fc%persp) then
                    call rasterize_persp_clipped(fc, vv)
                else
                    call rasterize_tri(fc, vv)
                end if
            end do
        end do
    end subroutine rasterize_face

    ! Clip a view-space triangle against the near plane (depth >=
    ! near_d, i.e. z <= -near_d) and fan-rasterise the polygon.
    subroutine rasterize_persp_clipped(fc, vv)
        type(shadow_face), intent(inout) :: fc
        real(dp), intent(in) :: vv(3, 3)
        real(dp) :: poly(3, 4), tri(3, 3)
        integer :: np, i
        real(dp) :: dcur, dprev, t
        logical :: cur_in, prev_in
        np = 0
        do i = 1, 3
            block
                integer :: ip
                real(dp) :: cur(3), prev(3)
                ip = i - 1
                if (ip < 1) ip = 3
                prev = vv(:, ip)
                cur = vv(:, i)
                dprev = -prev(3) - fc%near_d
                dcur = -cur(3) - fc%near_d
                prev_in = dprev >= 0.0_dp
                cur_in = dcur >= 0.0_dp
                if (cur_in .neqv. prev_in) then
                    t = dprev / (dprev - dcur)
                    np = np + 1
                    poly(:, np) = prev + (cur - prev) * t
                end if
                if (cur_in) then
                    np = np + 1
                    poly(:, np) = cur
                end if
            end block
        end do
        if (np < 3) return
        do i = 2, np - 1
            tri(:, 1) = poly(:, 1)
            tri(:, 2) = poly(:, i)
            tri(:, 3) = poly(:, i + 1)
            call rasterize_tri(fc, tri)
        end do
    end subroutine rasterize_persp_clipped

    subroutine rasterize_tri(fc, vv)
        type(shadow_face), intent(inout) :: fc
        real(dp), intent(in) :: vv(3, 3)
        integer :: sz, ix, iy, ix0, ix1, iy0, iy1, k
        real(dp) :: sx(3), sy(3), dep(3), invw(3), ndc(2), d
        real(dp) :: area, e0, e1, e2, l0, l1, l2, px, py, dd

        sz = shadow_v3_map_size
        do k = 1, 3
            d = -vv(3, k)
            dep(k) = d
            if (fc%persp) then
                if (abs(d) < 1.0e-12_dp) return  ! degenerate corner
                invw(k) = 1.0_dp / d
                ndc(1) = vv(1, k) / (d * fc%tan_half)
                ndc(2) = vv(2, k) / (d * fc%tan_half)
            else
                invw(k) = 1.0_dp
                ndc(1) = 2.0_dp * (vv(1, k) - fc%left) &
                         / (fc%right - fc%left) - 1.0_dp
                ndc(2) = 2.0_dp * (vv(2, k) - fc%bottom) &
                         / (fc%top - fc%bottom) - 1.0_dp
            end if
            sx(k) = (ndc(1) + 1.0_dp) * 0.5_dp * real(sz, dp)
            sy(k) = (1.0_dp - ndc(2)) * 0.5_dp * real(sz, dp)
        end do
        area = (sx(2) - sx(1)) * (sy(3) - sy(1)) &
             - (sy(2) - sy(1)) * (sx(3) - sx(1))
        if (abs(area) < 1.0e-18_dp) return
        ix0 = max(1, int(minval(sx)) )
        ix1 = min(sz, int(maxval(sx)) + 1)
        iy0 = max(1, int(minval(sy)) )
        iy1 = min(sz, int(maxval(sy)) + 1)
        do iy = iy0, iy1
            py = real(iy, dp) - 0.5_dp
            do ix = ix0, ix1
                px = real(ix, dp) - 0.5_dp
                e0 = (sx(3) - sx(2)) * (py - sy(2)) &
                   - (sy(3) - sy(2)) * (px - sx(2))
                e1 = (sx(1) - sx(3)) * (py - sy(3)) &
                   - (sy(1) - sy(3)) * (px - sx(3))
                e2 = (sx(2) - sx(1)) * (py - sy(1)) &
                   - (sy(2) - sy(1)) * (px - sx(1))
                l0 = e0 / area
                l1 = e1 / area
                l2 = e2 / area
                if (l0 < -1.0e-12_dp .or. l1 < -1.0e-12_dp &
                    .or. l2 < -1.0e-12_dp) cycle
                if (fc%persp) then
                    dd = l0 * invw(1) + l1 * invw(2) + l2 * invw(3)
                    if (abs(dd) < 1.0e-18_dp) cycle
                    d = 1.0_dp / dd
                else
                    d = l0 * dep(1) + l1 * dep(2) + l2 * dep(3)
                end if
                if (d < fc%near_d .or. d > fc%far_d) cycle
                if (d < real(fc%depth(ix, iy), dp)) &
                    fc%depth(ix, iy) = real(d, real32)
            end do
        end do
    end subroutine rasterize_tri

end module shadow_v3_3d
