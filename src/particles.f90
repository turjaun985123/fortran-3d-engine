! particles.f90 -- deterministic particle systems (MASTER-PLAN row 32).
!
! Determinism contract (FROZEN; the JS (B72) and Python (B73) mirrors
! follow this EXACTLY -- integer hash, no transcendentals except the
! trig-free velocity formula below):
!   * Same seed, same t  =>  same frame, on every backend.
!   * A particle's state is a pure function of (system, index, t):
!     there is no simulation state, no accumulation, no wall clock.
!
!   hash01(seed, i, k):  i = particle index 0-based, k = channel 0,1,2;
!   integer(int64) arithmetic, reduced mod 2^31 at each step:
!       x = mod(seed*1103515245 + i*12345 + k*67890, 2147483648)
!       x = mod(x*1103515245 + 12345, 2147483648)
!       hash01 = real(x, dp) / 2147483648.0       ! in [0,1)
!
!   Particle i at time t (origin O, count N, life L, speed S,
!   spread V, gravity G):
!       age = mod(t + i * (L / max(N,1)), L)   ! staggered spawns;
!                                              ! if L <= 0 -> age 0
!       vel = ( (h0-0.5)*2*V*S ,  S*(0.5+0.5*h1) ,  (h2-0.5)*2*V*S )
!             where hk = hash01(seed, i, k)
!       pos = O + vel*age + (0, -0.5*G*age*age, 0)
!       scale_out = 1 - age/L                  ! if L <= 0 -> 0
!
! Defaults are frozen: spread 0.5, gravity 0.0 (gravity is opt-in, so
! the default motion is a clean fountain with vy positive).
!
! Module independence: this module uses only math_3d and mesh_3d. The
! billboard basis below duplicates the sprite contract (~15 lines) on
! purpose -- it does NOT use any sprite module.
module particles_3d
    use, intrinsic :: iso_fortran_env, only: int64
    use math_3d
    ! MeshType alias: the frozen dummy name `mesh` in
    ! particles_build_mesh would otherwise collide (case-insensitively)
    ! with the type name Mesh.
    use mesh_3d, only: MeshType => Mesh, Triangle
    implicit none
    private
    public :: ParticleSystem, particle_system_init, &
              particle_hash01, particle_state, particles_build_mesh

    type :: ParticleSystem
        type(vec3) :: origin = vec3(0.0_dp, 0.0_dp, 0.0_dp)
        integer :: count = 100
        real(dp) :: life = 2.0_dp
        real(dp) :: speed = 3.0_dp
        real(dp) :: size = 0.2_dp
        real(dp) :: spread = 0.5_dp
        real(dp) :: gravity = 0.0_dp
        integer :: seed = 1
        integer :: color(3) = [255, 180, 60]
    end type ParticleSystem

    ! 2^31, the hash modulus (frozen).
    integer(int64), parameter :: HASH_MOD = 2147483648_int64

contains

    ! Reset sys to the frozen defaults (origin via vec3_create).
    subroutine particle_system_init(sys)
        type(ParticleSystem), intent(out) :: sys

        sys%origin = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
        sys%count = 100
        sys%life = 2.0_dp
        sys%speed = 3.0_dp
        sys%size = 0.2_dp
        sys%spread = 0.5_dp
        sys%gravity = 0.0_dp
        sys%seed = 1
        sys%color = [255, 180, 60]
    end subroutine particle_system_init

    ! Frozen integer hash -> [0,1). seed, i, k are integers; i is the
    ! 0-based particle index and k the channel (0, 1, 2). All
    ! arithmetic is integer(int64) reduced mod 2^31 at each step, so
    ! no intermediate exceeds ~2.4e18 and nothing overflows int64 for
    ! any default-integer seed / index / channel.
    pure function particle_hash01(seed, i, k) result(u)
        integer, intent(in) :: seed, i, k
        real(dp) :: u
        integer(int64) :: x

        x = mod(int(seed, int64) * 1103515245_int64 + &
                int(i, int64) * 12345_int64 + &
                int(k, int64) * 67890_int64, HASH_MOD)
        x = mod(x * 1103515245_int64 + 12345_int64, HASH_MOD)
        u = real(x, dp) / 2147483648.0_dp
    end function particle_hash01

    ! State of particle i (1-based Fortran API; converted to the
    ! 0-based index of the frozen contract internally) at time t.
    subroutine particle_state(sys, i, t, pos, scale_out)
        type(ParticleSystem), intent(in) :: sys
        integer, intent(in) :: i
        real(dp), intent(in) :: t
        type(vec3), intent(out) :: pos
        real(dp), intent(out) :: scale_out

        integer :: idx, n
        real(dp) :: age, h0, h1, h2
        type(vec3) :: vel

        idx = i - 1
        if (sys%life <= 0.0_dp) then
            age = 0.0_dp
            scale_out = 0.0_dp
            pos = sys%origin
            return
        end if

        n = max(sys%count, 1)
        age = mod(t + real(idx, dp) * (sys%life / real(n, dp)), sys%life)

        h0 = particle_hash01(sys%seed, idx, 0)
        h1 = particle_hash01(sys%seed, idx, 1)
        h2 = particle_hash01(sys%seed, idx, 2)
        vel = vec3_create( &
            (h0 - 0.5_dp) * 2.0_dp * sys%spread * sys%speed, &
            sys%speed * (0.5_dp + 0.5_dp * h1), &
            (h2 - 0.5_dp) * 2.0_dp * sys%spread * sys%speed)

        pos = vec3_add(sys%origin, vec3_scale(vel, age))
        pos%y = pos%y - 0.5_dp * sys%gravity * age * age
        scale_out = 1.0_dp - age / sys%life
    end subroutine particle_state

    ! Build one billboard quad (2 triangles) per LIVE particle
    ! (scale_out > 0) at time t, facing cam_pos. Quad side is
    ! sys%size * scale_out; colour is sys%color on every triangle.
    subroutine particles_build_mesh(sys, t, cam_pos, mesh)
        type(ParticleSystem), intent(in) :: sys
        real(dp), intent(in) :: t
        type(vec3), intent(in) :: cam_pos
        type(MeshType), intent(inout) :: mesh

        integer :: i, live, idx
        type(vec3) :: center, view_dir, up_hint, right, up2
        type(vec3) :: c_bl, c_br, c_tr, c_tl
        real(dp) :: scale_out, half
        type(vec3) :: pos_tmp
        real(dp) :: sc_tmp

        if (allocated(mesh%triangles)) deallocate(mesh%triangles)

        ! First pass: count live particles (state is a pure function
        ! of (sys, i, t), so the second pass reproduces it exactly).
        live = 0
        do i = 1, max(sys%count, 0)
            call particle_state(sys, i, t, pos_tmp, sc_tmp)
            if (sc_tmp > 0.0_dp) live = live + 1
        end do

        mesh%num_triangles = live * 2
        allocate(mesh%triangles(mesh%num_triangles))
        if (live == 0) return

        idx = 0
        do i = 1, max(sys%count, 0)
            call particle_state(sys, i, t, center, scale_out)
            if (scale_out <= 0.0_dp) cycle

            ! Billboard basis (sprite contract, duplicated here for
            ! module independence -- do not factor into a sprite use):
            view_dir = vec3_normalize(vec3_sub(center, cam_pos))
            up_hint = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
            if (abs(vec3_dot(view_dir, up_hint)) > 0.999_dp) &
                up_hint = vec3_create(1.0_dp, 0.0_dp, 0.0_dp)
            right = vec3_normalize(vec3_cross(up_hint, view_dir))
            up2 = vec3_cross(view_dir, right)

            half = 0.5_dp * sys%size * scale_out
            c_bl = vec3_add(vec3_sub(center, vec3_scale(right, half)), &
                            vec3_scale(up2, -half))
            c_br = vec3_add(vec3_add(center, vec3_scale(right, half)), &
                            vec3_scale(up2, -half))
            c_tr = vec3_add(vec3_add(center, vec3_scale(right, half)), &
                            vec3_scale(up2, half))
            c_tl = vec3_add(vec3_sub(center, vec3_scale(right, half)), &
                            vec3_scale(up2, half))

            ! Winding mirrored EXACTLY from sprite.f90's
            ! sprite_build_mesh: with corners labelled (sprite names
            ! a/b/c/d) a = c_bl, b = c_br, c = c_tr, d = c_tl, its
            ! triangles are [a,b,c] and [a,c,d]. That ordering -- not
            ! the previous [c_bl,c_tr,c_br]/[c_bl,c_tl,c_tr] -- is
            ! the one whose projected screen-space cross product
            !   (sx2-sx1)*(sy3-sy1) - (sy2-sy1)*(sx3-sx1)
            ! is > 0 for a camera in front, i.e. the winding
            ! renderer_3d's screen-space cull keeps (the old order
            ! was culled, rendering 0 particle pixels). Stored
            ! normal also mirrors sprite_build_mesh: -view_dir,
            ! facing the camera (sprite sets it explicitly rather
            ! than from the winding's geometric normal).
            idx = idx + 1
            mesh%triangles(idx)%v = [c_bl, c_br, c_tr]
            mesh%triangles(idx)%normal = vec3_negate(view_dir)
            mesh%triangles(idx)%color = sys%color
            idx = idx + 1
            mesh%triangles(idx)%v = [c_bl, c_tr, c_tl]
            mesh%triangles(idx)%normal = vec3_negate(view_dir)
            mesh%triangles(idx)%color = sys%color
        end do
        mesh%num_triangles = idx
    end subroutine particles_build_mesh

end module particles_3d
