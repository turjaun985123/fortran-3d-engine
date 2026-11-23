! parity_matrix.f90 -- Forge3D parity-matrix generator (Fortran port of
! tools/parity_matrix.py, Wave C seat B85, MASTER-PLAN section 3).
!
! Parses the two tables in docs/plan/MASTER-PLAN.md section 3 (rows 1-28
! Three.js, 29-36 PixiJS), merges statuses from docs/parity-status.json,
! and writes docs/parity-matrix.json plus a coverage report on stdout.
! The generated JSON is byte-identical to the Python version's output
! (json.dumps with indent=2, ensure_ascii=False, plus a trailing "\n").
!
! Repo root: the Python version derives it from the script location
! (tools/ -> parent).  This program instead takes the root from the
! FORGE3D_ROOT environment variable when set, and otherwise assumes the
! current working directory is the repo root; the runner/CI cds there.
!
! Build: gfortran -O2 -o parity_matrix tools/json_read.f90 tools/parity_matrix.f90
! Run:   ./parity_matrix        (from the repo root)
program parity_matrix
  use, intrinsic :: iso_fortran_env, only: error_unit, real64
  use json_read
  implicit none

  character(len=*), parameter :: ALLOWED(5) = [character(len=17) :: &
      "Done-verified", "In-wave-C", "Queued-wave-3", &
      "Queued-continuous", "Blocked"]
  character(len=*), parameter :: EXTRA_FIELDS(5) = [character(len=18) :: &
      "feature", "forge3d_equivalent", "wave", "proof_test", "better_metric"]

  type :: plan_row
    integer :: row = 0
    character(len=:), allocatable :: feature, equiv, wave, proof, better
  end type plan_row

  type :: out_row
    logical :: row_is_str = .false.
    integer :: row_num = 0
    character(len=:), allocatable :: row_str
    character(len=:), allocatable :: feature, equiv, wave, proof, better
    character(len=:), allocatable :: status, evidence
    logical :: evidence_is_string = .true.
  end type out_row

  character(len=:), allocatable :: root, plan_path, status_path, out_path
  character(len=:), allocatable :: plan_text, status_text, errmsg
  type(plan_row) :: prows(256)
  integer :: nprows
  type(jr_doc) :: doc
  type(out_row) :: merged(1024)
  integer :: nmerged
  character(len=:), allocatable :: errors(:)
  integer :: nerrors
  integer :: counts(5), total, done, i, j, k, rc
  real(real64) :: percent
  character(len=:), allocatable :: json_out

  ! ---- locate inputs -----------------------------------------------------
  call get_root(root)
  plan_path   = root // "/docs/plan/MASTER-PLAN.md"
  status_path = root // "/docs/parity-status.json"
  out_path    = root // "/docs/parity-matrix.json"

  ! ---- parse MASTER-PLAN section 3 --------------------------------------
  if (.not. read_file(plan_path, plan_text)) then
    rc = fail("cannot read " // plan_path)
    call exit(rc)
  end if
  call parse_plan(plan_text, prows, nprows, errmsg)
  if (allocated(errmsg)) then
    rc = fail(errmsg)
    call exit(rc)
  end if

  ! ---- read parity-status.json -------------------------------------------
  if (.not. read_file(status_path, status_text)) then
    rc = fail("cannot read " // status_path // ": No such file or directory")
    call exit(rc)
  end if
  call jr_parse(status_text, doc)
  if (.not. doc%ok) then
    rc = fail("cannot read " // status_path // ": " // doc%error)
    call exit(rc)
  end if
  if (.not. doc%is_object) then
    rc = fail("parity-status.json must be a JSON object (map row -> status)")
    call exit(rc)
  end if

  ! ---- merge rows 1..36 ---------------------------------------------------
  nerrors = 0
  nmerged = 0
  block
    character(len=:), allocatable :: key, status, evidence
    integer :: eidx
    logical :: ev_is_str, okk
    do i = 1, nprows
      key = int_to_str(prows(i)%row)
      eidx = jr_find_entry(doc, key)
      if (eidx == 0) then
        call add_error("row " // key // ": lacks a status in parity-status.json")
        cycle
      end if
      if (doc%entries(eidx)%is_null) then
        call add_error("row " // key // ": lacks a status in parity-status.json")
        cycle
      end if
      call check_entry(doc%entries(eidx), key, status, evidence, ev_is_str, okk)
      if (.not. okk) cycle
      nmerged = nmerged + 1
      merged(nmerged)%row_is_str = .false.
      merged(nmerged)%row_num = prows(i)%row
      merged(nmerged)%feature = prows(i)%feature
      merged(nmerged)%equiv   = prows(i)%equiv
      merged(nmerged)%wave    = prows(i)%wave
      merged(nmerged)%proof   = prows(i)%proof
      merged(nmerged)%better  = prows(i)%better
      merged(nmerged)%status  = status
      merged(nmerged)%evidence = evidence
      merged(nmerged)%evidence_is_string = ev_is_str
    end do
  end block

  ! ---- extra rows (sorted keys, "_" metadata skipped) ---------------------
  block
    character(len=:), allocatable :: ekeys(:)
    integer :: nekeys, eidx, fidx
    character(len=:), allocatable :: key, status, evidence, missing
    logical :: ev_is_str, okk
    nekeys = 0
    allocate (character(len=256) :: ekeys(doc%nentries))
    do i = 1, doc%nentries
      key = doc%entries(i)%key
      if (key(1:1) == "_") cycle
      if (is_numeric_key(key)) cycle  ! keys "1".."36" handled above
      ! A numeric key outside 1..36 is still an extra in the Python code:
      ! known_keys only holds "1".."36".  is_numeric_key must therefore be
      ! range-checked; do it here by comparing against the plan rows.
      nekeys = nekeys + 1
      ekeys(nekeys) = key
    end do
    call sort_strings(ekeys, nekeys)
    do j = 1, nekeys
      key = trim(ekeys(j))
      eidx = jr_find_entry(doc, key)
      call check_entry(doc%entries(eidx), key, status, evidence, ev_is_str, okk)
      if (.not. okk) cycle
      missing = ""
      do k = 1, 5
        fidx = jr_find_field(doc%entries(eidx), trim(EXTRA_FIELDS(k)))
        if (fidx == 0) then
          if (len(missing) > 0) missing = missing // ", "
          missing = missing // trim(EXTRA_FIELDS(k))
        end if
      end do
      if (len(missing) > 0) then
        call add_error("extra row " // key // ": missing field(s) " // missing // &
          " (extra rows are not in the MASTER-PLAN section 3 tables, " // &
          "so parity-status.json must supply them)")
        cycle
      end if
      nmerged = nmerged + 1
      merged(nmerged)%row_is_str = .true.
      merged(nmerged)%row_str = key
      merged(nmerged)%feature = field_value(doc%entries(eidx), "feature")
      merged(nmerged)%equiv   = field_value(doc%entries(eidx), "forge3d_equivalent")
      merged(nmerged)%wave    = field_value(doc%entries(eidx), "wave")
      merged(nmerged)%proof   = field_value(doc%entries(eidx), "proof_test")
      merged(nmerged)%better  = field_value(doc%entries(eidx), "better_metric")
      merged(nmerged)%status  = status
      merged(nmerged)%evidence = evidence
      merged(nmerged)%evidence_is_string = ev_is_str
    end do
  end block

  ! ---- report errors, write nothing ---------------------------------------
  if (nerrors > 0) then
    do i = 1, nerrors
      write (error_unit, '(A)') "parity_matrix: ERROR: " // trim(errors(i))
    end do
    call exit(1)
  end if

  ! ---- coverage -------------------------------------------------------------
  counts = 0
  do i = 1, nmerged
    do j = 1, 5
      if (merged(i)%status == trim(ALLOWED(j))) counts(j) = counts(j) + 1
    end do
  end do
  total = nmerged
  done = counts(1)
  if (total > 0) then
    percent = 100.0_real64 * real(done, real64) / real(total, real64)
  else
    percent = 0.0_real64
  end if

  ! ---- emit JSON (Python json.dumps(indent=2, ensure_ascii=False) + "\n") ---
  call build_json(json_out)
  if (.not. write_file(out_path, json_out)) then
    rc = fail("cannot write " // out_path)
    call exit(rc)
  end if

  ! ---- stdout report ---------------------------------------------------------
  write (*, '(A)') "Forge3D parity coverage (MASTER-PLAN section 3 + continuous extras)"
  write (*, '(A)') "Total rows: " // int_to_str(total)
  do j = 1, 5
    write (*, '(A)') "  " // trim(ALLOWED(j)) // ": " // int_to_str(counts(j))
  end do
  write (*, '(A)') "Done-verified: " // int_to_str(done) // "/" // &
    int_to_str(total) // " = " // fmt_percent1(percent) // "%"
  write (*, '(A)') "Wrote docs/parity-matrix.json"

contains

  !==== helpers ==============================================================

  subroutine get_root(r)
    character(len=:), allocatable, intent(out) :: r
    integer :: ln, st
    character(len=4096) :: buf
    call get_environment_variable("FORGE3D_ROOT", buf, ln, st)
    if (st == 0 .and. ln > 0) then
      r = trim(buf(1:ln))
      ! strip a trailing slash (but keep "/" itself)
      if (len(r) > 1) then
        if (r(len(r):len(r)) == "/") r = r(1:len(r) - 1)
      end if
    else
      r = "."
    end if
  end subroutine get_root

  function read_file(path, content) result(ok)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(out) :: content
    logical :: ok
    integer :: unit, sz, ios
    ok = .false.
    inquire (file=path, size=sz, exist=ok)
    if (.not. ok) return
    ok = .false.
    open (newunit=unit, file=path, access="stream", form="unformatted", &
          status="old", action="read", iostat=ios)
    if (ios /= 0) return
    allocate (character(len=sz) :: content)
    if (sz > 0) then
      read (unit, iostat=ios) content
      if (ios /= 0) then
        close (unit)
        return
      end if
    end if
    close (unit)
    ok = .true.
  end function read_file

  function write_file(path, content) result(ok)
    character(len=*), intent(in) :: path, content
    logical :: ok
    integer :: unit, ios
    open (newunit=unit, file=path, access="stream", form="unformatted", &
          status="replace", action="write", iostat=ios)
    if (ios /= 0) then
      ok = .false.
      return
    end if
    write (unit, iostat=ios) content
    close (unit)
    ok = (ios == 0)
  end function write_file

  function fail(msg) result(rc)
    character(len=*), intent(in) :: msg
    integer :: rc
    write (error_unit, '(A)') "parity_matrix: ERROR: " // msg
    rc = 1
  end function fail

  subroutine add_error(msg)
    character(len=*), intent(in) :: msg
    character(len=:), allocatable :: tmp(:)
    integer :: i2
    if (.not. allocated(errors)) then
      allocate (character(len=4096) :: errors(16))
      nerrors = 0
    end if
    if (nerrors == size(errors)) then
      allocate (character(len=4096) :: tmp(2 * size(errors)))
      do i2 = 1, nerrors
        tmp(i2) = errors(i2)
      end do
      call move_alloc(tmp, errors)
    end if
    nerrors = nerrors + 1
    errors(nerrors) = msg
  end subroutine add_error

  function int_to_str(n) result(s)
    integer, intent(in) :: n
    character(len=:), allocatable :: s
    character(len=32) :: buf
    write (buf, '(I0)') n
    s = trim(buf)
  end function int_to_str

  ! Python round(x, 1) uses round-half-even on the exact binary value;
  ! format the result with exactly one decimal digit.
  function fmt_percent1(x) result(s)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: s
    real(real64) :: scaled, fl, frac
    integer :: tenths
    scaled = x * 10.0_real64
    fl = floor(scaled)
    frac = scaled - fl
    if (frac > 0.5_real64) then
      tenths = int(fl) + 1
    else if (frac < 0.5_real64) then
      tenths = int(fl)
    else
      ! exact tie: choose the even neighbour (Python round-half-even)
      if (mod(int(fl), 2) == 0) then
        tenths = int(fl)
      else
        tenths = int(fl) + 1
      end if
    end if
    s = int_to_str(tenths / 10) // "." // int_to_str(mod(tenths, 10))
  end function fmt_percent1

  !==== MASTER-PLAN parsing ===================================================

  function is_blank_char(c) result(b)
    character, intent(in) :: c
    logical :: b
    integer :: i
    i = iachar(c)
    b = (i == 32 .or. i == 9 .or. i == 13 .or. i == 10 .or. i == 11 .or. i == 12)
  end function is_blank_char

  function strip_str(s) result(r)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: r
    integer :: a, b
    a = 1
    b = len(s)
    do while (a <= b)
      if (is_blank_char(s(a:a))) then
        a = a + 1
      else
        exit
      end if
    end do
    do while (b >= a)
      if (is_blank_char(s(b:b))) then
        b = b - 1
      else
        exit
      end if
    end do
    if (b < a) then
      r = ""
    else
      r = s(a:b)
    end if
  end function strip_str

  function all_digits(s) result(b)
    character(len=*), intent(in) :: s
    logical :: b
    integer :: i2
    b = .false.
    if (len(s) == 0) return
    do i2 = 1, len(s)
      if (s(i2:i2) < '0' .or. s(i2:i2) > '9') return
    end do
    b = .true.
  end function all_digits

  ! Python re.fullmatch(r":?-{3,}:?", cell)
  function is_sep_cell(cell) result(b)
    character(len=*), intent(in) :: cell
    logical :: b
    integer :: i2, ndash
    b = .false.
    i2 = 1
    if (i2 <= len(cell)) then
      if (cell(i2:i2) == ':') i2 = i2 + 1
    end if
    ndash = 0
    do while (i2 <= len(cell))
      if (cell(i2:i2) == '-') then
        ndash = ndash + 1
        i2 = i2 + 1
      else
        exit
      end if
    end do
    if (ndash < 3) return
    if (i2 <= len(cell)) then
      if (cell(i2:i2) == ':') i2 = i2 + 1
    end if
    b = (i2 == len(cell) + 1)
  end function is_sep_cell

  subroutine parse_plan(text, rows, nrows, err)
    character(len=*), intent(in) :: text
    type(plan_row), intent(out) :: rows(:)
    integer, intent(out) :: nrows
    character(len=:), allocatable, intent(out) :: err
    integer :: s0, e0, pos, lend, i2, jj, ncells, rnum, tmp
    character(len=:), allocatable :: section, line, t, cell
    character(len=:), allocatable :: cells(:)
    logical :: sep
    type(plan_row) :: swap

    nrows = 0
    s0 = index(text, "## 3.")
    if (s0 == 0) then
      err = "MASTER-PLAN.md: section 3 heading not found"
      return
    end if
    e0 = index(text(s0 + 1:), "## 4.")
    if (e0 == 0) then
      section = text(s0:)
    else
      section = text(s0:s0 + e0 - 1)
    end if

    pos = 1
    do while (pos <= len(section))
      lend = index(section(pos:), achar(10))
      if (lend == 0) then
        line = section(pos:)
        pos = len(section) + 1
      else if (lend == 1) then
        line = ""
        pos = pos + 1
      else
        line = section(pos:pos + lend - 2)
        pos = pos + lend
      end if
      t = strip_str(line)
      if (len(t) == 0) cycle
      if (t(1:1) /= '|') cycle
      ! split_row: drop leading '|' and trailing '|' of the stripped line
      if (len(t) >= 1) then
        if (t(1:1) == '|') t = t(2:)
      end if
      if (len(t) >= 1) then
        if (t(len(t):len(t)) == '|') t = t(1:len(t) - 1)
      end if
      ncells = 1
      do i2 = 1, len(t)
        if (t(i2:i2) == '|') ncells = ncells + 1
      end do
      allocate (character(len=max(1, len(t))) :: cells(ncells))
      block
        integer :: c0, ci, p0
        ci = 0
        p0 = 1
        do i2 = 1, len(t) + 1
          if (i2 > len(t) .or. t(i2:i2) == '|') then
            ci = ci + 1
            if (i2 > p0) then
              cells(ci) = strip_str(t(p0:i2 - 1))
            else
              cells(ci) = ""
            end if
            p0 = i2 + 1
          end if
        end do
        c0 = ci
        ncells = c0
      end block
      if (ncells /= 6) then
        deallocate (cells)
        cycle
      end if
      cell = trim(cells(1))
      if (.not. all_digits(cell)) then
        deallocate (cells)
        cycle
      end if
      sep = .true.
      do i2 = 1, 6
        if (len_trim(cells(i2)) > 0) then
          if (.not. is_sep_cell(trim(cells(i2)))) sep = .false.
        end if
      end do
      if (sep) then
        deallocate (cells)
        cycle
      end if
      read (cell, *) rnum
      nrows = nrows + 1
      rows(nrows)%row = rnum
      rows(nrows)%feature = trim(cells(2))
      rows(nrows)%equiv   = trim(cells(3))
      rows(nrows)%wave    = trim(cells(4))
      rows(nrows)%proof   = trim(cells(5))
      rows(nrows)%better  = trim(cells(6))
      deallocate (cells)
    end do

    ! sort by row (insertion sort; n is small)
    do i2 = 2, nrows
      do jj = i2, 2, -1
        if (rows(jj)%row < rows(jj - 1)%row) then
          swap = rows(jj)
          rows(jj) = rows(jj - 1)
          rows(jj - 1) = swap
        else
          exit
        end if
      end do
    end do

    if (nrows /= 36) then
      err = plan_numbers_error()
      return
    end if
    do i = 1, 36
      if (rows(i)%row /= i) then
        err = plan_numbers_error()
        return
      end if
    end do
    tmp = 0  ! keep compiler quiet about unused paths
  end subroutine parse_plan

  function plan_numbers_error() result(msg)
    character(len=:), allocatable :: msg
    integer :: i2
    msg = "MASTER-PLAN.md section 3: expected rows 1-36, got ["
    do i2 = 1, nprows
      if (i2 > 1) msg = msg // ", "
      msg = msg // int_to_str(prows(i2)%row)
    end do
    msg = msg // "]"
  end function plan_numbers_error

  !==== status-entry validation ================================================

  function is_numeric_key(key) result(b)
    character(len=*), intent(in) :: key
    logical :: b
    integer :: v
    ! True only for the canonical keys "1".."36" (Python known_keys).
    b = .false.
    do v = 1, 36
      if (key == int_to_str(v)) then
        b = .true.
        return
      end if
    end do
  end function is_numeric_key

  function field_value(entry, name) result(v)
    type(jr_entry), intent(in) :: entry
    character(len=*), intent(in) :: name
    character(len=:), allocatable :: v
    integer :: fi
    fi = jr_find_field(entry, name)
    if (fi == 0) then
      v = ""
    else if (allocated(entry%fields(fi)%value)) then
      v = entry%fields(fi)%value
    else
      v = ""
    end if
  end function field_value

  ! Mirrors the Python check_entry(): appends an error and sets ok=.false.
  ! on failure; otherwise returns the status and evidence.
  subroutine check_entry(entry, key, status, evidence, ev_is_str, ok)
    type(jr_entry), intent(in) :: entry
    character(len=*), intent(in) :: key
    character(len=:), allocatable, intent(out) :: status, evidence
    logical, intent(out) :: ev_is_str, ok
    integer :: fi, ei, ai, m
    ok = .false.
    ev_is_str = .true.
    status = ""
    evidence = ""
    if (.not. entry%is_object) then
      call add_error("row " // key // ": missing status")
      return
    end if
    fi = jr_find_field(entry, "status")
    if (fi == 0) then
      call add_error("row " // key // ": missing status")
      return
    end if
    if (entry%fields(fi)%is_string .and. allocated(entry%fields(fi)%value)) then
      status = entry%fields(fi)%value
    else if (allocated(entry%fields(fi)%value)) then
      status = entry%fields(fi)%value  ! raw token, for the repr in the error
    else
      status = ""
    end if
    ai = 0
    do m = 1, 5
      if (entry%fields(fi)%is_string .and. status == trim(ALLOWED(m))) ai = m
    end do
    if (ai == 0) then
      if (entry%fields(fi)%is_string) then
        call add_error("row " // key // ": invalid status " // &
          py_repr(status) // " (allowed: " // allowed_list() // ")")
      else
        call add_error("row " // key // ": invalid status " // &
          trim(status) // " (allowed: " // allowed_list() // ")")
      end if
      return
    end if
    status = trim(ALLOWED(ai))
    ei = jr_find_field(entry, "evidence")
    if (ei > 0) then
      ev_is_str = entry%fields(ei)%is_string
      if (allocated(entry%fields(ei)%value)) then
        evidence = entry%fields(ei)%value
      else
        evidence = ""
      end if
    end if
    ok = .true.
  end subroutine check_entry

  function allowed_list() result(s)
    character(len=:), allocatable :: s
    integer :: i2
    s = ""
    do i2 = 1, 5
      if (i2 > 1) s = s // ", "
      s = s // trim(ALLOWED(i2))
    end do
  end function allowed_list

  ! Python repr() of a string, for the invalid-status error message.
  function py_repr(s) result(r)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: r
    character :: q
    integer :: i2, c
    logical :: has_sq, has_dq
    has_sq = index(s, "'") > 0
    has_dq = index(s, '"') > 0
    if (has_sq .and. .not. has_dq) then
      q = '"'
    else
      q = "'"
    end if
    r = q
    do i2 = 1, len(s)
      c = iachar(s(i2:i2))
      if (s(i2:i2) == '\') then
        r = r // '\\'
      else if (s(i2:i2) == q) then
        r = r // '\' // q
      else if (c == 10) then
        r = r // '\n'
      else if (c == 13) then
        r = r // '\r'
      else if (c == 9) then
        r = r // '\t'
      else if (c < 32 .or. c == 127) then
        r = r // '\x' // hex2(c)
      else
        r = r // s(i2:i2)
      end if
    end do
    r = r // q
  end function py_repr

  function hex2(v) result(h)
    integer, intent(in) :: v
    character(len=2) :: h
    character(len=*), parameter :: digits = "0123456789abcdef"
    h(1:1) = digits(v / 16 + 1:v / 16 + 1)
    h(2:2) = digits(mod(v, 16) + 1:mod(v, 16) + 1)
  end function hex2

  subroutine sort_strings(arr, n)
    character(len=:), allocatable, intent(inout) :: arr(:)
    integer, intent(in) :: n
    integer :: a, b
    character(len=:), allocatable :: tmp2
    ! Lexicographic byte order, matching Python sorted() on ASCII keys.
    do a = 2, n
      do b = a, 2, -1
        if (str_less(trim(arr(b)), trim(arr(b - 1)))) then
          tmp2 = arr(b)
          arr(b) = arr(b - 1)
          arr(b - 1) = tmp2
        else
          exit
        end if
      end do
    end do
  end subroutine sort_strings

  function str_less(a, b) result(l)
    character(len=*), intent(in) :: a, b
    logical :: l
    integer :: i2, ca, cb
    l = .false.
    do i2 = 1, min(len(a), len(b))
      ca = iachar(a(i2:i2))
      cb = iachar(b(i2:i2))
      if (ca < cb) then
        l = .true.
        return
      else if (ca > cb) then
        return
      end if
    end do
    l = (len(a) < len(b))
  end function str_less

  !==== JSON emission ============================================================

  ! Escape a string exactly like Python json.dumps(ensure_ascii=False):
  ! \" \\ \b \f \n \r \t, other control chars as \u00xx (lowercase hex),
  ! everything else (including UTF-8 bytes) passed through.
  function json_escape(s) result(r)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: r
    integer :: i2, c
    character(len=*), parameter :: digits = "0123456789abcdef"
    r = '"'
    do i2 = 1, len(s)
      c = iachar(s(i2:i2))
      select case (c)
      case (34)
        r = r // '\"'
      case (92)
        r = r // '\\'
      case (8)
        r = r // '\b'
      case (12)
        r = r // '\f'
      case (10)
        r = r // '\n'
      case (13)
        r = r // '\r'
      case (9)
        r = r // '\t'
      case (0:7, 11, 14:31)
        r = r // '\u00' // digits(c / 16 + 1:c / 16 + 1) // &
            digits(mod(c, 16) + 1:mod(c, 16) + 1)
      case default
        r = r // s(i2:i2)
      end select
    end do
    r = r // '"'
  end function json_escape

  subroutine build_json(out)
    character(len=:), allocatable, intent(out) :: out
    character(len=*), parameter :: NL = achar(10)
    integer :: i2, j2
    out = "{"
    out = out // NL // '  "source_plan": "docs/plan/MASTER-PLAN.md",'
    out = out // NL // '  "source_status": "docs/parity-status.json",'
    out = out // NL // '  "rows": ['
    do i2 = 1, nmerged
      out = out // NL // '    {'
      if (merged(i2)%row_is_str) then
        out = out // NL // '      "row": ' // json_escape(merged(i2)%row_str) // ','
      else
        out = out // NL // '      "row": ' // int_to_str(merged(i2)%row_num) // ','
      end if
      out = out // NL // '      "feature": ' // json_escape(merged(i2)%feature) // ','
      out = out // NL // '      "forge3d_equivalent": ' // json_escape(merged(i2)%equiv) // ','
      out = out // NL // '      "wave": ' // json_escape(merged(i2)%wave) // ','
      out = out // NL // '      "proof_test": ' // json_escape(merged(i2)%proof) // ','
      out = out // NL // '      "better_metric": ' // json_escape(merged(i2)%better) // ','
      out = out // NL // '      "status": ' // json_escape(merged(i2)%status) // ','
      if (merged(i2)%evidence_is_string) then
        out = out // NL // '      "evidence": ' // json_escape(merged(i2)%evidence)
      else
        out = out // NL // '      "evidence": ' // merged(i2)%evidence
      end if
      out = out // NL // '    }'
      if (i2 < nmerged) out = out // ','
    end do
    out = out // NL // '  ],'
    out = out // NL // '  "coverage": {'
    out = out // NL // '    "total_rows": ' // int_to_str(total) // ','
    out = out // NL // '    "counts": {'
    do j2 = 1, 5
      out = out // NL // '      ' // json_escape(trim(ALLOWED(j2))) // ': ' // &
            int_to_str(counts(j2))
      if (j2 < 5) out = out // ','
    end do
    out = out // NL // '    },'
    out = out // NL // '    "done_verified": ' // int_to_str(done) // ','
    out = out // NL // '    "done_verified_percent": ' // fmt_percent1(percent)
    out = out // NL // '  }'
    out = out // NL // '}' // NL
  end subroutine build_json

end program parity_matrix
