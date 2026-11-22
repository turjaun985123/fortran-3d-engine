program main
    use math_3d
    use mesh_3d
    use camera_3d
    use renderer_3d
    implicit none

    type(Mesh) :: cube
    type(Camera) :: cam
    type(FrameBuffer) :: fb
    type(mat4) :: model_rot_y, model_rot_x, model_matrix
    type(vec3) :: eye, target, light_dir
    integer :: width, height
    character(len=128) :: output_file

    width = 640
    height = 480
    output_file = 'output_render.ppm'

    print *, '============================================'
    print *, ' Fortran 3D Graphics Engine '
    print *, '============================================'

    ! 1. Initialize FrameBuffer
    print *, '[+] Initializing FrameBuffer (', width, 'x', height, ')...'
    call framebuffer_init(fb, width, height)

    ! 2. Create 3D geometry
    print *, '[+] Creating 3D Cube Mesh...'
    call create_cube(cube, 2.0_dp)
    print *, '    Triangles loaded:', cube%num_triangles

    ! 3. Set up Camera
    eye = vec3_create(3.0_dp, 2.5_dp, 4.0_dp)
    target = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    print *, '[+] Setting up Camera at (3.0, 2.5, 4.0) looking at (0, 0, 0)...'
    call camera_init(cam, eye, target, 60.0_dp, real(width, dp)/real(height, dp), 0.1_dp, 100.0_dp)

    ! 4. Set up Model Transform (rotate the cube slightly)
    model_rot_y = mat4_rotate_y(35.0_dp * PI / 180.0_dp)
    model_rot_x = mat4_rotate_x(20.0_dp * PI / 180.0_dp)
    model_matrix = mat4_mult(model_rot_y, model_rot_x)

    ! 5. Directional light source
    light_dir = vec3_create(-0.5_dp, -1.0_dp, -0.7_dp)

    ! 6. Render
    print *, '[+] Rasterizing mesh to FrameBuffer with Z-buffering & shading...'
    call framebuffer_render_mesh(fb, cube, model_matrix, cam, light_dir)

    ! 7. Save output PPM image
    print *, '[+] Writing image to ', trim(output_file), '...'
    call framebuffer_save_ppm(fb, output_file)

    ! 8. Export 3D Mesh for Interactive Web / 3D Viewers
    print *, '[+] Exporting scene.json and model.obj...'
    call export_mesh_json(cube, 'scene.json')
    call export_mesh_obj(cube, 'model.obj')

    print *, '============================================'
    print *, ' Rendering & Export successfully completed!'
    print *, ' Output files: '
    print *, '   - ', trim(output_file)
    print *, '   - scene.json'
    print *, '   - model.obj'
    print *, '============================================'

end program main
