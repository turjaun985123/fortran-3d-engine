! instancing.f90 -- true instancing data path (MASTER-PLAN parity row 22).
!
! v1 `repeat/grid/ring` expands copies at compile time: the scene source
! itself carries one object per copy.  An InstanceSet is the opposite
! shape: ONE base mesh plus a list of per-instance transforms (mat4).
! The instance count is preserved end-to-end in the source data --
! `count` transforms, no duplicated geometry -- and the set is rendered
! through a single entry point, instancing_build_mesh, whose output is
! one ordinary Mesh that the existing renderer entry points
! (framebuffer_render_mesh* in renderer_3d) consume unchanged.
!
! Honest realisation note: this engine's renderer is a CPU rasteriser
! with no per-instance draw call, so instancing_build_mesh BAKES the
! instances into a single mesh via mesh_add_transformed (one build,
! shared source geometry, per-instance transforms applied at build
! time).  The baked mesh has count * base%num_triangles triangles.
! The saving is in the source/authoring data and in having one build
! and one render entry point, not in baked triangle count.
module instancing_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: InstanceSet, instancing_init, instancing_add, &
              instancing_count, instancing_build_mesh, instancing_free

    type :: InstanceSet
        type(Mesh) :: base
        type(mat4), allocatable :: transforms(:)
        integer :: count = 0
    end type InstanceSet

contains

    ! (Re)initialise a set around a base mesh.  The base is deep-copied
    ! (derived-type assignment copies the allocatable triangles), so the
    ! caller keeps ownership of base_mesh.  Any previous transforms are
    ! dropped and the count resets to 0.
    subroutine instancing_init(set, base_mesh)
        type(InstanceSet), intent(inout) :: set
        type(Mesh), intent(in) :: base_mesh

        if (allocated(set%transforms)) deallocate(set%transforms)
        set%count = 0
        set%base = base_mesh
    end subroutine instancing_init

    ! Append one per-instance transform (growable, same tmp/move_alloc
    ! pattern as scene_3d's append_* helpers).
    subroutine instancing_add(set, m)
        type(InstanceSet), intent(inout) :: set
        type(mat4), intent(in) :: m
        type(mat4), allocatable :: tmp(:)
        integer :: n

        n = set%count
        allocate(tmp(n + 1))
        if (n > 0) tmp(1:n) = set%transforms(1:n)
        tmp(n + 1) = m
        if (allocated(set%transforms)) deallocate(set%transforms)
        call move_alloc(tmp, set%transforms)
        set%count = n + 1
    end subroutine instancing_add

    pure function instancing_count(set) result(n)
        type(InstanceSet), intent(in) :: set
        integer :: n
        n = set%count
    end function instancing_count

    ! Bake all instances into one mesh (see the header note).  out_mesh
    ! is reset first, so repeated builds do not accumulate.  An empty
    ! set (or an empty base) builds an empty mesh: num_triangles == 0.
    ! Per-instance colours come from the base mesh (use_color=.false.);
    ! material_id is set to 0, matching the builder-created base meshes.
    subroutine instancing_build_mesh(set, out_mesh)
        type(InstanceSet), intent(in) :: set
        type(Mesh), intent(inout) :: out_mesh
        integer :: rgb(3)
        integer :: i

        call free_mesh(out_mesh)
        out_mesh%num_triangles = 0
        if (set%count <= 0) return
        if (set%base%num_triangles <= 0) return
        rgb = [0, 0, 0]
        do i = 1, set%count
            call mesh_add_transformed(out_mesh, set%base, &
                set%transforms(i), .false., rgb, 0)
        end do
    end subroutine instancing_build_mesh

    subroutine instancing_free(set)
        type(InstanceSet), intent(inout) :: set

        if (allocated(set%transforms)) deallocate(set%transforms)
        set%count = 0
        call free_mesh(set%base)
    end subroutine instancing_free

end module instancing_3d
