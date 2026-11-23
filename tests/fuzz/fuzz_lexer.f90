! fuzz_lexer.f90 -- fuzz harness for the Forge3D compiler lexer
! (v3.0 Phase 9, hardening).  Standalone Fortran program, zero
! Python, written for the WAVE "write code only" pass: it is meant
! to be built and run by the Phase 9 verification pass, not here.
!
! What it does
! ------------
! Generates deterministic pseudo-random byte soups biased toward
! lexer-relevant bytes (word letters, digits, '.', '-', '"', '#',
! ',', ':', '/', whitespace, line breaks, NUL and high bytes
! 128..255), plus soups assembled from lexer-shaped fragments
! ("scene ", "640x480", "#FF00AA", an unterminated '"', a "//"
! comment opener, "-1.2.3", ...).  Each soup (length 0..512) is fed
! to the real compiler lexer:
!
!   call tokenize(source_text, source_name, tokens, bag)
!     subroutine tokenize(source_text, source_name, tokens, bag)
!       character(len=*), intent(in)    :: source_text, source_name
!       type(token_list), intent(out)   :: tokens
!       type(error_bag_t), intent(inout) :: bag
!     end subroutine
!
! from module f3dc_lexer (compiler/src/f3dc_lexer.f90).  The tokens
! and diagnostics produced are simply discarded (their counts and
! text lengths are folded into a running checksum that is printed
! at the end, so the calls cannot be optimised away).  The harness
! PASSES if it never crashes: no assertion is made about the token
! stream, because any byte soup is legal input -- the lexer must
! recover from all of it (E101/E102/E103/E820 diagnostics, never a
! crash, hang, out-of-bounds read or UB).  Run it under the
! sanitisers so memory/UB bugs abort the run loudly.
!
! Build recipe (from the repo root; mirrors how
! tests/native/property_fmt.f90 links compiler/src/f3dc_str.f90
! standalone, extended with the lexer's real dependency chain):
!
!   cc -c compiler/preview_http.c -o /tmp/preview_http.o
!   gfortran -g -O1 -fsanitize=address,undefined \
!       -fno-sanitize-recover=all \
!       -o /tmp/fuzz_lexer tests/fuzz/fuzz_lexer.f90 \
!       compiler/src/f3dc_lexer.f90 compiler/src/f3dc_errors.f90 \
!       compiler/src/f3dc_str.f90 /tmp/preview_http.o
!
! Exact link set (and why):
!   tests/fuzz/fuzz_lexer.f90   -- this harness (program fuzz_lexer)
!   compiler/src/f3dc_lexer.f90 -- module f3dc_lexer; the entry
!                                  under test is tokenize() above.
!   compiler/src/f3dc_errors.f90
!                               -- module f3dc_errors; f3dc_lexer
!                                  `use`s error_bag_t / span_t /
!                                  diagnostic_t / error_bag_add
!                                  from it (tokenize collects its
!                                  diagnostics in the caller's bag).
!   compiler/src/f3dc_str.f90   -- module f3dc_str; f3dc_errors
!                                  `use`s char_list / str_builder /
!                                  fmt_int / to_lower from it.
!                                  (f3dc_str itself depends only on
!                                  iso_fortran_env / ieee_arithmetic.)
!   compiler/preview_http.c     -- provides the bind(C) symbol
!                                  f3dc_isatty_stderr() referenced
!                                  by f3dc_errors (error_bag_use_
!                                  color).  This harness never calls
!                                  it, but the symbol must resolve
!                                  at link time.
! f3dc_dyn is NOT needed: tokenize returns a plain token_list of
! fixed-shape token records, not a dyn value, so no dyn_assign /
! dyn cleanup API is involved; discarding a result is just a
! deallocate of tokens%items (done explicitly each iteration).
!
! Run:
!   /tmp/fuzz_lexer [iterations] [seed]
!     iterations -- bounded iteration count, default 10000.
!     seed       -- PRNG seed (any int64; 0 is remapped to the
!                   default), default fixed at
!                   2685821657736338717, so a plain run is fully
!                   reproducible: same seed -> same soups -> the
!                   same crash, if any.  Progress is printed every
!                   1000 iterations and the run ends with
!                   "fuzz_lexer: N iterations, no crash".
!
! Fortran traps honoured throughout:
!   * .and. / .or. do NOT short-circuit, so every array/character
!     index is guarded by a nested if, never by a compound
!     condition that also indexes.
!   * The PRNG is plain xorshift64 (shifts + xor only, no
!     multiplication), so it cannot trip UBSan signed-overflow on
!     the int64 state the way a splitmix64 multiply could.

program fuzz_lexer
  use, intrinsic :: iso_fortran_env, only: int64
  use f3dc_lexer, only: tokenize, token_list
  use f3dc_errors, only: error_bag_t, error_bag_len
  implicit none

  integer, parameter :: MAX_SOUP = 512
  integer(int64), parameter :: DEFAULT_SEED = 2685821657736338717_int64
  integer(int64), parameter :: DEFAULT_ITERS = 10000_int64

  integer(int64) :: rng_state
  integer(int64) :: n_iters, seed, iter
  integer :: soup_len, i
  character(len=MAX_SOUP) :: soup
  integer(int64) :: total_tokens, total_diags, total_chars
  character(len=64) :: arg
  integer :: ios

  ! ---- Command line: [iterations] [seed], both optional. ----
  n_iters = DEFAULT_ITERS
  seed = DEFAULT_SEED
  if (command_argument_count() >= 1) then
    call get_command_argument(1, arg)
    read (arg, *, iostat=ios) n_iters
    if (ios /= 0) n_iters = DEFAULT_ITERS
    if (n_iters < 0_int64) n_iters = DEFAULT_ITERS
  end if
  if (command_argument_count() >= 2) then
    call get_command_argument(2, arg)
    read (arg, *, iostat=ios) seed
    if (ios /= 0) seed = DEFAULT_SEED
  end if
  if (seed == 0_int64) seed = DEFAULT_SEED  ! xorshift state /= 0
  rng_state = seed

  write (*, '(A,I0,A,I0)') 'fuzz_lexer: iterations=', n_iters, &
    ' seed=', seed

  total_tokens = 0_int64
  total_diags = 0_int64
  total_chars = 0_int64

  do iter = 1_int64, n_iters
    ! Fresh bag + token list per iteration: the block scope makes
    ! the allocatable components (bag%diags, tokens%items) release
    ! automatically at end block, so a runaway allocation in one
    ! soup cannot accumulate across iterations.
    block
      type(error_bag_t) :: bag
      type(token_list) :: tokens
      character(len=:), allocatable :: text
      integer :: k

      call make_soup(soup, soup_len)
      allocate (character(len=soup_len) :: text)
      if (soup_len > 0) text = soup(1:soup_len)

      call tokenize(text, '<fuzz>', tokens, bag)

      ! Discard the results, folding their shape into checksums so
      ! the lexer call is observable and cannot be optimised away.
      total_tokens = total_tokens + int(tokens%count, int64)
      total_diags = total_diags + int(error_bag_len(bag), int64)
      if (allocated(tokens%items)) then
        do k = 1, tokens%count
          if (allocated(tokens%items(k)%text)) then
            total_chars = total_chars + &
              int(len(tokens%items(k)%text), int64)
          end if
        end do
        deallocate (tokens%items)
      end if
      deallocate (text)
    end block

    if (mod(iter, 1000_int64) == 0_int64) then
      write (*, '(A,I0,A,I0)') 'fuzz_lexer: ', iter, ' / ', n_iters
    end if
  end do

  write (*, '(A,I0,A,I0,A,I0)') &
    'fuzz_lexer: checksum tokens=', total_tokens, &
    ' diags=', total_diags, ' token_chars=', total_chars
  write (*, '(A,I0,A)') 'fuzz_lexer: ', n_iters, &
    ' iterations, no crash'

contains

  ! ----------------------------------------------------------------
  ! xorshift64 PRNG (Marsaglia): period 2**64 - 1 for any non-zero
  ! state; shifts and xors only.  The result is masked to a
  ! non-negative int64 so mod() below behaves like a true modulo.
  ! ----------------------------------------------------------------
  function next_rand() result(r)
    integer(int64) :: r
    rng_state = ieor(rng_state, ishft(rng_state, 13))
    rng_state = ieor(rng_state, ishft(rng_state, -7))
    rng_state = ieor(rng_state, ishft(rng_state, 17))
    r = iand(rng_state, huge(0_int64))
  end function next_rand

  ! Uniform-ish integer in [lo, hi] (caller guarantees lo <= hi).
  function rand_range(lo, hi) result(v)
    integer, intent(in) :: lo, hi
    integer :: v
    v = lo + int(mod(next_rand(), int(hi - lo + 1, int64)))
  end function rand_range

  ! ----------------------------------------------------------------
  ! Soup generation: 3 fragment-assembled soups in every 10, the
  ! rest raw byte soups.  Length is always within 0..MAX_SOUP.
  ! ----------------------------------------------------------------
  subroutine make_soup(buf, n)
    character(len=MAX_SOUP), intent(out) :: buf
    integer, intent(out) :: n
    if (rand_range(1, 10) <= 3) then
      call make_fragment_soup(buf, n)
    else
      call make_byte_soup(buf, n)
    end if
  end subroutine make_soup

  subroutine make_byte_soup(buf, n)
    character(len=MAX_SOUP), intent(out) :: buf
    integer, intent(out) :: n
    integer :: j
    n = rand_range(0, MAX_SOUP)
    do j = 1, n
      buf(j:j) = achar(pick_byte())
    end do
  end subroutine make_byte_soup

  ! One byte, biased by category (percentages in the comments).
  function pick_byte() result(b)
    integer :: b, cat, k
    ! Character classes the lexer actually branches on.
    character(len=*), parameter :: WORD_CH = &
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_'
    character(len=*), parameter :: DIGITS = '0123456789'
    character(len=*), parameter :: PUNCT = '"#,:/.- '
    cat = rand_range(1, 100)
    if (cat <= 30) then
      ! 30%: word characters (letters / '_').
      k = rand_range(1, len(WORD_CH))
      b = iachar(WORD_CH(k:k))
    else if (cat <= 45) then
      ! 15%: digits and the decimal point (number lexing).
      if (rand_range(1, 4) == 1) then
        b = iachar('.')
      else
        k = rand_range(1, len(DIGITS))
        b = iachar(DIGITS(k:k))
      end if
    else if (cat <= 58) then
      ! 13%: lexer punctuation: quote, '#', comma, colon, slash,
      ! dot, dash, space.
      k = rand_range(1, len(PUNCT))
      b = iachar(PUNCT(k:k))
    else if (cat <= 68) then
      ! 10%: whitespace and line breaks: LF, CR, TAB, VT, FF.
      select case (rand_range(1, 5))
      case (1); b = 10
      case (2); b = 13
      case (3); b = 9
      case (4); b = 11
      case default; b = 12
      end select
    else if (cat <= 78) then
      ! 10%: hex digits (colour literals after '#').
      k = rand_range(1, 22)
      if (k <= 10) then
        b = iachar(DIGITS(k:k))
      else if (k <= 16) then
        b = iachar('a') + (k - 11)
      else
        b = iachar('A') + (k - 17)
      end if
    else if (cat <= 90) then
      ! 12%: high bytes 128..255 (invalid-UTF-8 / stray territory).
      b = rand_range(128, 255)
    else
      ! 10%: any byte at all, 0..255 (NUL included).
      b = rand_range(0, 255)
    end if
  end function pick_byte

  ! Soup assembled from lexer-shaped fragments, so near-valid token
  ! streams (the interesting crash territory: just past a colour's
  ! 6 hex digits, just inside an unterminated string, a number with
  ! too many dots) are hit far more often than raw bytes reach.
  subroutine make_fragment_soup(buf, n)
    character(len=MAX_SOUP), intent(out) :: buf
    integer, intent(out) :: n
    integer :: pieces, p, pos, flen, k
    character(len=:), allocatable :: frag
    n = 0
    pos = 1
    pieces = rand_range(1, 24)
    do p = 1, pieces
      call pick_fragment(frag)
      flen = len(frag)
      if (flen > 0) then
        if (pos + flen - 1 <= MAX_SOUP) then
          do k = 1, flen
            buf(pos + k - 1:pos + k - 1) = frag(k:k)
          end do
          pos = pos + flen
          n = pos - 1
        end if
      end if
    end do
  end subroutine make_fragment_soup

  subroutine pick_fragment(frag)
    character(len=:), allocatable, intent(out) :: frag
    select case (rand_range(1, 24))
    case (1);  frag = 'scene '
    case (2);  frag = 'box '
    case (3);  frag = 'camera '
    case (4);  frag = '640x480'
    case (5);  frag = '#FF00AA'
    case (6);  frag = '#12345'          ! one hex digit short
    case (7);  frag = '#1234567'        ! one hex digit too many
    case (8);  frag = '"texture.png"'
    case (9);  frag = '"unterminated'   ! E103 territory
    case (10); frag = '""'
    case (11); frag = '// comment to end of line'
    case (12); frag = '# not a colour: comment'
    case (13); frag = '-1.5'
    case (14); frag = '1.2.3'           ! E102 territory
    case (15); frag = '12x'
    case (16); frag = '-'
    case (17); frag = '.'
    case (18); frag = ','
    case (19); frag = ':'
    case (20); frag = 'at 0, 1, -2' // achar(10)
    case (21); frag = 'end' // achar(10)
    case (22); frag = achar(13) // achar(10)
    case (23); frag = achar(0) // achar(200) // achar(255)
    case default; frag = '  '
    end select
  end subroutine pick_fragment

end program fuzz_lexer
