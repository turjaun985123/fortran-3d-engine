! mesh_data.f90 -- indexed structure-of-arrays mesh data (v3.0 Phase 1,
! finding G1).
!
! Before Phase 1 every builder in mesh_3d / geo_*_3d produced an
! unindexed triangle soup (type Mesh in mesh_3d) and UVs did not exist
! as data at all: the renderer synthesised them per corner from a
! primitive name via texture_3d's prim_uv().  This module introduces
! the indexed representation the rest of the v3.0 pipeline builds on:
!
!   type mesh_data
!     pos(3, n_verts)  real32 vertex positions
!     nrm(3, n_verts)  real32 vertex normals (may be unallocated on
!                      input -> mesh_data_finalize computes smooth
!                      vertex normals from idx)
!     uv (2, n_verts)  real32 REAL UVs, stored per vertex
!     tan(4, n_verts)  real32 tangents (optional; unallocated in
!                      Phase 1 -- no builder computes tangents yet)
!     idx(3, n_tris)   1-based triangle indices into the vertex arrays
!     bmin / bmax      bounds, filled by mesh_data_finalize
!
! Builders (build_<name>_data in mesh.f90 and the geo_* modules) emit
! SHARED vertices: a grid vertex used by four triangles is stored
! once.  Vertices are duplicated only where a single vertex cannot
! carry the data -- across a UV seam (u wraps 1 -> 0), across a
! smooth/flat shading boundary (caps vs barrel), or between faces of
! a flat-shaded solid (per-face normals).  Each builder documents its
! exact vertex / triangle counts.
!
! Legacy-precision shadow (deliberate, documented deviation):
! the legacy Triangle soup is double precision and the frozen legacy
! renderer (ADR-1) plus the pre-Phase-1 test suite pin builder output
! to ~1e-9 in dp (e.g. torus vertex normals, circle rim radii).  A
! pure real32 round-trip through create_* would move vertices by
! ~1e-7 and break both.  Builders therefore ALSO fill optional dp
! shadow arrays (pos_dp / nrm_dp / tnrm_dp) with the exact dp values
! they computed, and the conversion shim (mesh_data_to_triangles in
! mesh_3d -- it lives there, not here, because mesh_3d's builders use
! this module and Fortran forbids the circular module use that a
! shim here would need) prefers the shadow when present.  The real32
! arrays are complete and authoritative for new (Phase 2+) consumers;
! a mesh_data built by hand without shadows converts through the
! real32 arrays alone.  col / smooth_tri carry the legacy per-triangle
! colour and smooth-shading flag, which the indexed core spec has no
! other home for.
module mesh_data_3d
    use, intrinsic :: iso_fortran_env, only: real32
    use math_3d, only: dp, vec3
    implicit none
    private
    public :: mesh_data, mesh_data_alloc, mesh_data_put_vertex, &
              mesh_data_put_tri, mesh_data_finalize, mesh_data_free, &
              mesh_data_face_uv

    type :: mesh_data
        real(real32), allocatable :: pos(:, :)   ! 3 x n_verts
        real(real32), allocatable :: nrm(:, :)   ! 3 x n_verts (optional)
        real(real32), allocatable :: uv(:, :)    ! 2 x n_verts
        real(real32), allocatable :: tan(:, :)   ! 4 x n_verts (unused, Phase 1)
        integer, allocatable :: idx(:, :)        ! 3 x n_tris, 1-based
        integer :: n_verts = 0
        integer :: n_tris = 0
        real(real32) :: bmin(3) = 0.0_real32
        real(real32) :: bmax(3) = 0.0_real32
        ! Legacy-compat extensions (see header): per-triangle colour
        ! and smooth flag for the Triangle-soup shim, and the optional
        ! dp shadow of pos / nrm / per-triangle normals.
        integer, allocatable :: col(:, :)        ! 3 x n_tris, 0..255
        logical, allocatable :: smooth_tri(:)    ! n_tris
        real(dp), allocatable :: pos_dp(:, :)    ! 3 x n_verts
        real(dp), allocatable :: nrm_dp(:, :)    ! 3 x n_verts
        real(dp), allocatable :: tnrm_dp(:, :)   ! 3 x n_tris
    end type mesh_data

contains

    ! Allocate all arrays for nv vertices / nt triangles.  Normals,
    ! colours, smooth flags, triangle normals and the dp shadow are
    ! always allocated by this helper (builders fill them via
    ! mesh_data_put_vertex / mesh_data_put_tri); tan stays unallocated.
    subroutine mesh_data_alloc(md, nv, nt)
        type(mesh_data), intent(inout) :: md
        integer, intent(in) :: nv, nt

        call mesh_data_free(md)
        md%n_verts = nv
        md%n_tris = nt
        if (nv > 0) then
            allocate(md%pos(3, nv), md%nrm(3, nv), md%uv(2, nv))
            allocate(md%pos_dp(3, nv), md%nrm_dp(3, nv))
            md%pos = 0.0_real32
            md%nrm = 0.0_real32
            md%uv = 0.0_real32
            md%pos_dp = 0.0_dp
            md%nrm_dp = 0.0_dp
        end if
        if (nt > 0) then
            allocate(md%idx(3, nt), md%col(3, nt), md%smooth_tri(nt))
            allocate(md%tnrm_dp(3, nt))
            md%idx = 0
            md%col = 255
            md%smooth_tri = .false.
            md%tnrm_dp = 0.0_dp
        end if
    end subroutine mesh_data_alloc

    ! Store one vertex: dp position / normal / uv are written to the
    ! dp shadow verbatim and rounded once into the real32 arrays.
    subroutine mesh_data_put_vertex(md, i, p, n, uv)
        type(mesh_data), intent(inout) :: md
        integer, intent(in) :: i
        type(vec3), intent(in) :: p, n
        real(dp), intent(in) :: uv(2)

        md%pos(:, i) = real([p%x, p%y, p%z], real32)
        md%nrm(:, i) = real([n%x, n%y, n%z], real32)
        md%uv(:, i) = real(uv, real32)
        md%pos_dp(:, i) = [p%x, p%y, p%z]
        md%nrm_dp(:, i) = [n%x, n%y, n%z]
    end subroutine mesh_data_put_vertex

    ! Store one triangle: corner indices, the legacy per-triangle
    ! normal (exact dp value the pre-Phase-1 builder would have set),
    ! the smooth flag and the colour.
    subroutine mesh_data_put_tri(md, t, a, b, c, tn, smooth, rgb)
        type(mesh_data), intent(inout) :: md
        integer, intent(in) :: t, a, b, c
        type(vec3), intent(in) :: tn
        logical, intent(in) :: smooth
        integer, intent(in) :: rgb(3)

        md%idx(:, t) = [a, b, c]
        md%tnrm_dp(:, t) = [tn%x, tn%y, tn%z]
        md%smooth_tri(t) = smooth
        md%col(:, t) = rgb
    end subroutine mesh_data_put_tri

    ! Compute bounds from pos; when nrm is unallocated, compute smooth
    ! vertex normals from idx (area-weighted face-normal accumulation,
    ! normalised).  The dp shadow normal array is filled alongside
    ! whenever the shadow position array is present.
    subroutine mesh_data_finalize(md)
        type(mesh_data), intent(inout) :: md
        integer :: i, t, k, vi
        real(dp) :: acc(3), e1(3), e2(3), fn(3), p(3, 3), len

        if (md%n_verts <= 0 .or. .not. allocated(md%pos)) then
            md%bmin = 0.0_real32
            md%bmax = 0.0_real32
            return
        end if
        md%bmin = md%pos(:, 1)
        md%bmax = md%pos(:, 1)
        do i = 2, md%n_verts
            do k = 1, 3
                md%bmin(k) = min(md%bmin(k), md%pos(k, i))
                md%bmax(k) = max(md%bmax(k), md%pos(k, i))
            end do
        end do

        if (allocated(md%nrm)) return
        allocate(md%nrm(3, md%n_verts))
        md%nrm = 0.0_real32
        if (allocated(md%pos_dp)) then
            if (.not. allocated(md%nrm_dp)) &
                allocate(md%nrm_dp(3, md%n_verts))
            md%nrm_dp = 0.0_dp
        end if
        if (.not. allocated(md%idx)) return
        do t = 1, md%n_tris
            do k = 1, 3
                vi = md%idx(k, t)
                if (allocated(md%pos_dp)) then
                    p(:, k) = md%pos_dp(:, vi)
                else
                    p(:, k) = real(md%pos(:, vi), dp)
                end if
            end do
            e1 = p(:, 2) - p(:, 1)
            e2 = p(:, 3) - p(:, 1)
            fn = [e1(2) * e2(3) - e1(3) * e2(2), &
                  e1(3) * e2(1) - e1(1) * e2(3), &
                  e1(1) * e2(2) - e1(2) * e2(1)]
            do k = 1, 3
                vi = md%idx(k, t)
                acc = real(md%nrm(:, vi), dp) + fn
                md%nrm(:, vi) = real(acc, real32)
                if (allocated(md%nrm_dp)) md%nrm_dp(:, vi) = &
                    md%nrm_dp(:, vi) + fn
            end do
        end do
        do i = 1, md%n_verts
            acc = real(md%nrm(:, i), dp)
            len = sqrt(acc(1)**2 + acc(2)**2 + acc(3)**2)
            if (len > 0.0_dp) md%nrm(:, i) = real(acc / len, real32)
            if (allocated(md%nrm_dp)) then
                acc = md%nrm_dp(:, i)
                len = sqrt(acc(1)**2 + acc(2)**2 + acc(3)**2)
                if (len > 0.0_dp) md%nrm_dp(:, i) = acc / len
            end if
        end do
    end subroutine mesh_data_finalize

    subroutine mesh_data_free(md)
        type(mesh_data), intent(inout) :: md
        if (allocated(md%pos)) deallocate(md%pos)
        if (allocated(md%nrm)) deallocate(md%nrm)
        if (allocated(md%uv)) deallocate(md%uv)
        if (allocated(md%tan)) deallocate(md%tan)
        if (allocated(md%idx)) deallocate(md%idx)
        if (allocated(md%col)) deallocate(md%col)
        if (allocated(md%smooth_tri)) deallocate(md%smooth_tri)
        if (allocated(md%pos_dp)) deallocate(md%pos_dp)
        if (allocated(md%nrm_dp)) deallocate(md%nrm_dp)
        if (allocated(md%tnrm_dp)) deallocate(md%tnrm_dp)
        md%n_verts = 0
        md%n_tris = 0
        md%bmin = 0.0_real32
        md%bmax = 0.0_real32
    end subroutine mesh_data_free

    ! Per-face planar UV projection -- the same orientation contract
    ! as texture_3d's prim_uv box rule, but evaluated for ONE known
    ! face (axis = 1/2/3 for X/Y/Z, sgn = +/-1) instead of guessing
    ! the face from the vertex.  Split vertices on that face therefore
    ! get exactly the UVs prim_uv would give the face's interior.
    !   +Z: u from +x, v from +y     -Z: u from -x, v from +y
    !   +X: u from -z, v from +y     -X: u from +z, v from +y
    !   +Y: u from +x, v from -z     -Y: u from +x, v from +z
    pure function mesh_data_face_uv(p, ext, axis, sgn) result(uv)
        type(vec3), intent(in) :: p
        real(dp), intent(in) :: ext(3)
        integer, intent(in) :: axis, sgn
        real(dp) :: uv(2)

        select case (axis)
        case (3)
            if (sgn >= 0) then
                uv = [axis_map(p%x, ext(1)), axis_map(p%y, ext(2))]
            else
                uv = [1.0_dp - axis_map(p%x, ext(1)), axis_map(p%y, ext(2))]
            end if
        case (1)
            if (sgn >= 0) then
                uv = [1.0_dp - axis_map(p%z, ext(3)), axis_map(p%y, ext(2))]
            else
                uv = [axis_map(p%z, ext(3)), axis_map(p%y, ext(2))]
            end if
        case default
            if (sgn >= 0) then
                uv = [axis_map(p%x, ext(1)), 1.0_dp - axis_map(p%z, ext(3))]
            else
                uv = [axis_map(p%x, ext(1)), axis_map(p%z, ext(3))]
            end if
        end select
        uv(1) = min(1.0_dp, max(0.0_dp, uv(1)))
        uv(2) = min(1.0_dp, max(0.0_dp, uv(2)))
    end function mesh_data_face_uv

    pure function axis_map(coord, extent) result(t)
        real(dp), intent(in) :: coord, extent
        real(dp) :: t
        if (extent > 0.0_dp) then
            t = coord / extent + 0.5_dp
        else
            t = 0.5_dp
        end if
    end function axis_map

end module mesh_data_3d
