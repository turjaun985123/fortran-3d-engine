! text_render.f90 -- bitmap text as geometry (MASTER-PLAN row 24).
!
! Module text_render_3d, Wave B seat B68.  Turns a character string
! into a mesh_3d Mesh of flat quads (2 triangles per lit pixel) so
! that `text "..."` works in the NATIVE render too, with no texture
! or font file needed at run time.  The JS seat (B69) mirrors this
! exact frozen font contract; seat B73 cross-checks both files.
!
! ---------------------------------------------------------------------
! FROZEN FONT CONTRACT -- do not change without changing both sides
! ---------------------------------------------------------------------
! Charset / index string (43 glyphs, index 0 first):
!   " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!?-:'"
!   0 = space, 1 = A, ..., 26 = Z, 27 = 0, ..., 36 = 9, 37 = '.',
!   38 = '!', 39 = '?', 40 = '-', 41 = ':', 42 = apostrophe.
!
! Each glyph is a 5-wide x 7-tall bitmap encoded as ONE integer(8)
! mask: bit (34 - (row*5 + col)) is set when the pixel at
! (row 0 = top, col 0 = left) is on.  Unknown characters map to '?'
! (index 39); lowercase input is uppercased by the builder.
!
! Glyph rows for 'A' (index 1), '#' = on, '.' = off:
!   .###.
!   #...#
!   #...#
!   #####
!   #...#
!   #...#
!   #...#
! Glyph rows for 'B' (index 2):
!   ####.
!   #...#
!   #...#
!   ####.
!   #...#
!   #...#
!   ####.
! Glyph rows for '0' (index 27):
!   .###.
!   #...#
!   #..##
!   #.#.#
!   ##..#
!   #...#
!   .###.
!
! ---------------------------------------------------------------------
! Geometry contract
! ---------------------------------------------------------------------
! Let ph = size/7 (pixel height) and pw = ph (square pixels).
! Glyph width = 5*pw, cell advance = 6*pw.  Text height = size,
! baseline at origin%y, text lies in the XY plane facing +Z
! (normal (0,0,1)), starting at origin%x and extending +x.
! Every ON pixel becomes a quad = 2 triangles, all carrying
! color_rgb.  Empty text -> 0 triangles.  The mesh triangle array
! is allocated exactly (ON pixels are counted before filling).
module text_render_3d
    use math_3d
    ! Mesh is renamed on import so the frozen dummy name `mesh` in
    ! text_build_mesh does not shadow the derived-type name.
    use mesh_3d, only: MeshT => Mesh
    implicit none
    private
    public :: GLYPH_MASKS, TEXT_CHARSET, &
              text_glyph_index, text_glyph_mask, &
              text_build_mesh, text_width

    character(len=43), parameter :: TEXT_CHARSET = &
        " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!?-:'"

    ! 5x7 glyph masks, index 0..42 in TEXT_CHARSET order (see the
    ! header for the bit layout and the A / B / 0 row diagrams).
    integer(8), parameter :: GLYPH_MASKS(0:42) = [ &
        0_8,           & !  0 ' ' (space)
        15621670449_8, & !  1 'A'
        32801506878_8, & !  2 'B'
        16660316687_8, & !  3 'C'
        32801080894_8, & !  4 'D'
        33840644639_8, & !  5 'E'
        33840644624_8, & !  6 'F'
        16660547118_8, & !  7 'G'
        18842895921_8, & !  8 'H'
        33424543903_8, & !  9 'I'
        7585466956_8,  & ! 10 'J'
        18879369809_8, & ! 11 'K'
        17734058527_8, & ! 12 'L'
        19182306865_8, & ! 13 'M'
        19119394417_8, & ! 14 'N'
        15621211694_8, & ! 15 'O'
        32801505808_8, & ! 16 'P'
        15621215821_8, & ! 17 'Q'
        32801509969_8, & ! 18 'R'
        16660235326_8, & ! 19 'S'
        33424543876_8, & ! 20 'T'
        18842437166_8, & ! 21 'U'
        18842436932_8, & ! 22 'V'
        18842572657_8, & ! 23 'W'
        18593485137_8, & ! 24 'X'
        18834657412_8, & ! 25 'Y'
        33321787935_8, & ! 26 'Z'
        15623448110_8, & ! 27 '0'
        4701950094_8,  & ! 28 '1'
        15603929375_8, & ! 29 '2'
        32247317566_8, & ! 30 '3'
        2359917634_8,  & ! 31 '4'
        33854359086_8, & ! 32 '5'
        15587034670_8, & ! 33 '6'
        33321783428_8, & ! 34 '7'
        15621113390_8, & ! 35 '8'
        15621129262_8, & ! 36 '9'
        396_8,         & ! 37 '.'
        4433514500_8,  & ! 38 '!'
        15603929092_8, & ! 39 '?'
        1015808_8,     & ! 40 '-'
        138416256_8,   & ! 41 ':'
        4437573632_8 ]   ! 42 ''' (apostrophe)

contains

    ! Index of ch in TEXT_CHARSET (0-based).  Lowercase letters map
    ! to their uppercase glyph; anything not in the charset maps
    ! to '?' (index 39).
    pure function text_glyph_index(ch) result(idx)
        character(1), intent(in) :: ch
        integer :: idx
        character(1) :: up
        integer :: code, pos

        up = ch
        code = iachar(ch)
        if (code >= iachar('a') .and. code <= iachar('z')) then
            up = achar(code - iachar('a') + iachar('A'))
        end if
        pos = index(TEXT_CHARSET, up)
        if (pos <= 0) then
            idx = 39
        else
            idx = pos - 1
        end if
    end function text_glyph_index

    ! Mask for a glyph index.  Out-of-range indices return the '?'
    ! mask (index 39), matching the unknown-character rule.
    pure function text_glyph_mask(idx) result(mask)
        integer, intent(in) :: idx
        integer(8) :: mask
        if (idx < 0 .or. idx > 42) then
            mask = GLYPH_MASKS(39)
        else
            mask = GLYPH_MASKS(idx)
        end if
    end function text_glyph_mask

    ! Total advance width of text at the given size: one cell of
    ! 6*(size/7) per character, minus the trailing (size/7) gap
    ! after the last glyph.  Empty text has width 0.
    pure function text_width(text, size) result(w)
        character(len=*), intent(in) :: text
        real(dp), intent(in) :: size
        real(dp) :: w
        if (len(text) <= 0) then
            w = 0.0_dp
        else
            w = real(len(text), dp) * 6.0_dp * (size / 7.0_dp) - (size / 7.0_dp)
        end if
    end function text_width

    ! Build text as a mesh of pixel quads in the XY plane facing
    ! +Z, per the geometry contract in the header.  The output mesh
    ! is (re)allocated exactly: num_triangles == 2 * (ON pixels).
    subroutine text_build_mesh(text, origin, size, color_rgb, mesh)
        character(len=*), intent(in) :: text
        type(vec3), intent(in) :: origin
        real(dp), intent(in) :: size
        integer, intent(in) :: color_rgb(3)
        type(MeshT), intent(inout) :: mesh
        integer(8) :: mask
        integer :: i, row, col, tri, on_pixels
        real(dp) :: ph, pw, advance, gx, x0, x1, y0, y1
        type(vec3) :: bl, br, tr, tl, nrm

        if (allocated(mesh%triangles)) deallocate(mesh%triangles)

        ph = size / 7.0_dp
        pw = ph
        advance = 6.0_dp * pw

        ! Count ON pixels first so the allocation is exact.
        on_pixels = 0
        do i = 1, len(text)
            on_pixels = on_pixels + popcnt(text_glyph_mask(text_glyph_index(text(i:i))))
        end do

        mesh%num_triangles = on_pixels * 2
        allocate(mesh%triangles(mesh%num_triangles))
        if (mesh%num_triangles == 0) return

        nrm = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
        tri = 0
        do i = 1, len(text)
            mask = text_glyph_mask(text_glyph_index(text(i:i)))
            gx = origin%x + real(i - 1, dp) * advance
            do row = 0, 6
                ! Row 0 is the TOP row: it sits highest in +y.
                y1 = origin%y + size - real(row, dp) * ph
                y0 = y1 - ph
                do col = 0, 4
                    if (.not. btest(mask, 34 - (row * 5 + col))) cycle
                    x0 = gx + real(col, dp) * pw
                    x1 = x0 + pw
                    bl = vec3_create(x0, y0, origin%z)
                    br = vec3_create(x1, y0, origin%z)
                    tr = vec3_create(x1, y1, origin%z)
                    tl = vec3_create(x0, y1, origin%z)
                    ! Winding flipped (2nd/3rd vertex swapped in
                    ! each triangle vs. a plain CCW-from-+Z order):
                    ! renderer_3d culls on the SCREEN-space cross
                    ! product (screen y is inverted), and only this
                    ! order gives a cross > 0 -- i.e. is kept --
                    ! when viewed from the front (+Z side), as
                    ! sprite_3d's [a,b,c]/[a,c,d] order does for its
                    ! corners.  The stored normal stays the declared
                    ! facing (0,0,1); renderer_3d recomputes the
                    ! geometric normal for shading anyway.
                    tri = tri + 1
                    mesh%triangles(tri)%v = [bl, tr, br]
                    mesh%triangles(tri)%normal = nrm
                    mesh%triangles(tri)%color = color_rgb
                    tri = tri + 1
                    mesh%triangles(tri)%v = [bl, tl, tr]
                    mesh%triangles(tri)%normal = nrm
                    mesh%triangles(tri)%color = color_rgb
                end do
            end do
        end do
        mesh%num_triangles = tri
    end subroutine text_build_mesh

end module text_render_3d
