;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           **** WAVPACK ****                            ;;
;;                  Hybrid Lossless Wavefile Compressor                   ;;
;;              Copyright (c) 1998 - 2015 Conifer Software.               ;;
;;                          All Rights Reserved.                          ;;
;;      Distributed under the BSD Software License (see license.txt)      ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

        include <ksamd64.inc>

        public  pack_decorr_stereo_pass_cont_rev_x64win
        public  pack_decorr_stereo_pass_cont_x64win

asmcode segment page 'CODE'

; This module contains X64 assembly optimized versions of functions required
; to encode WavPack files.

; This is an assembly optimized version of the following WavPack function:
;
; void pack_decorr_stereo_pass (
;   struct decorr_pass *dpp,
;   int32_t *buffer,
;   int32_t sample_count);
;
; It performs a single pass of stereo decorrelation, in place, as specified
; by the decorr_pass structure. Note that this function does NOT return the
; dpp->samples_X[] values in the "normalized" positions for terms 1-8, so if
; the number of samples is not a multiple of MAX_TERM, these must be moved if
; they are to be used somewhere else.
;
; This is written to work on an X86-64 processor (also called the AMD64)
; running in 64-bit mode and uses the MMX extensions to improve the
; performance by processing both stereo channels together. It is based on
; the original MMX code written by Joachim Henke that used MMX intrinsics
; called from C. Many thanks to Joachim for that!
;
; An issue with using MMX for this is that the sample history array in the
; decorr_pass structure contains separate arrays for each channel while the
; MMX code wants there to be a single array of dual samples. The fix for
; this is to convert the data in the arrays on entry and exit, and this is
; made easy by the fact that the 8 MMX regsiters hold exactly the required
; amount of data (64 bytes)!
;
; This is written to work on an X86-64 processor (also called the AMD64)
; running in 64-bit mode. This version is for the 64-bit Windows ABI and
; provides appropriate prologs and epilogs for stack unwinding. The
; arguments are passed in registers:
;
;   struct decorr_pass *dpp       rcx
;   int32_t *buffer               rdx
;   int32_t sample_count          r8d
;
; During the processing loops, the following registers are used:
;
;   rdi         buffer pointer
;   rsi         termination buffer pointer
;   rax,rbx,rdx used in default term to reduce calculation         
;   rbp         decorr_pass pointer
;   mm0, mm1    scratch
;   mm2         original sample values
;   mm3         correlation samples
;   mm4         0 (for pcmpeqd)
;   mm5         weights
;   mm6         delta
;   mm7         512 (for rounding)
;

pack_decorr_stereo_pass_x64win proc frame
        push_reg    rbp                     ; save non-volatile registers on stack
        push_reg    rbx                     ; (alphabetically)
        push_reg    rdi
        push_reg    rsi
        alloc_stack 8                       ; allocate 8 bytes on stack & align to 16 bytes
        end_prologue

        mov     rdi, rcx                    ; copy params from win regs to Linux regs
        mov     rsi, rdx                    ; so we can leave following code similar
        mov     rdx, r8
        mov     rcx, r9

        mov     rbp, rdi                    ; rbp = *dpp
        mov     rdi, rsi                    ; rdi = inbuffer
        mov     esi, edx
        sal     esi, 3
        jz      bdone
        add     rsi, rdi                    ; rsi = termination buffer pointer

        ; convert samples_A and samples_B array into samples_AB array for MMX
        ; (the MMX registers provide exactly enough storage to do this easily)

        movq        mm0, [rbp+16]
        punpckldq   mm0, [rbp+48]
        movq        mm1, [rbp+16]
        punpckhdq   mm1, [rbp+48]
        movq        mm2, [rbp+24]
        punpckldq   mm2, [rbp+56]
        movq        mm3, [rbp+24]
        punpckhdq   mm3, [rbp+56]
        movq        mm4, [rbp+32]
        punpckldq   mm4, [rbp+64]
        movq        mm5, [rbp+32]
        punpckhdq   mm5, [rbp+64]
        movq        mm6, [rbp+40]
        punpckldq   mm6, [rbp+72]
        movq        mm7, [rbp+40]
        punpckhdq   mm7, [rbp+72]

        movq    [rbp+16], mm0
        movq    [rbp+24], mm1
        movq    [rbp+32], mm2
        movq    [rbp+40], mm3
        movq    [rbp+48], mm4
        movq    [rbp+56], mm5
        movq    [rbp+64], mm6
        movq    [rbp+72], mm7

        mov     eax, 512
        movd    mm7, eax
        punpckldq mm7, mm7                  ; mm7 = round (512)

        mov     eax, [rbp+4]
        movd    mm6, eax
        punpckldq mm6, mm6                  ; mm6 = delta (0-7)

        mov     eax, 0FFFFh                 ; mask high weights to zero for PMADDWD
        movd    mm5, eax
        punpckldq mm5, mm5                  ; mm5 = weight mask 0x0000FFFF0000FFFF
        pand    mm5, [rbp+8]                ; mm5 = weight_AB masked to 16-bit

        movq    mm4, [rbp+16]               ; preload samples_AB[0]

        mov     al, [rbp]                   ; get term and vector to correct loop
        cmp     al, 17
        je      buff_term_17_loop
        cmp     al, 18
        je      buff_term_18_loop
        cmp     al, -1
        je      buff_term_minus_1_loop
        cmp     al, -2
        je      buff_term_minus_2_loop
        cmp     al, -3
        je      buff_term_minus_3_loop

        pxor    mm4, mm4                    ; mm4 = 0 (for pcmpeqd)
        xor     eax, eax
        xor     ebx, ebx
        add     bl, [rbp]
        mov     ecx, 7
        and     ebx, ecx
        jmp     buff_default_term_loop

        align  64

buff_default_term_loop:
        movq    mm2, [rdi]                  ; mm2 = left_right
        movq    mm3, [rbp+16+rax*8]
        inc     eax
        and     eax, ecx
        movq    [rbp+16+rbx*8], mm2
        inc     ebx
        and     ebx, ecx

        movq    mm1, mm3
        paddd   mm1, mm1
        psrlw   mm1, 1
        pmaddwd mm1, mm5

        movq    mm0, mm3
        psrld   mm0, 15
        pmaddwd mm0, mm5

        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi], mm2                  ; store result
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        add     rdi, 8
        pcmpeqd mm2, mm4                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm4                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pxor    mm5, mm0
        paddw   mm5, mm2                    ; and add to weight_AB
        pxor    mm5, mm0
        cmp     rdi, rsi
        jnz     buff_default_term_loop

        jmp     bdone

        align  64

buff_term_17_loop:
        movq    mm3, mm4                    ; get previous calculated value
        paddd   mm3, mm4
        psubd   mm3, [rbp+24]
        movq    [rbp+24], mm4

        movq    mm1, mm3
        paddd   mm1, mm1
        psrlw   mm1, 1
        pmaddwd mm1, mm5

        movq    mm0, mm3
        psrld   mm0, 15
        pmaddwd mm0, mm5

        movq    mm2, [rdi]                  ; mm2 = left_right
        movq    mm4, mm2
        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi], mm2                  ; store result
        pxor    mm1, mm1
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        add     rdi, 8
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pxor    mm5, mm0
        paddw   mm5, mm2                    ; and add to weight_AB
        pxor    mm5, mm0
        cmp     rdi, rsi
        jnz     buff_term_17_loop

        movq    [rbp+16], mm4               ; post-store samples_AB[0]
        jmp     bdone

        align  64

buff_term_18_loop:
        movq    mm3, mm4                    ; get previous calculated value
        psubd   mm3, [rbp+24]
        psrad   mm3, 1
        paddd   mm3, mm4                    ; mm3 = sam_AB
        movq    [rbp+24], mm4

        movq    mm1, mm3
        paddd   mm1, mm1
        psrlw   mm1, 1
        pmaddwd mm1, mm5

        movq    mm0, mm3
        psrld   mm0, 15
        pmaddwd mm0, mm5

        movq    mm2, [rdi]                  ; mm2 = left_right
        movq    mm4, mm2
        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi], mm2                  ; store result
        pxor    mm1, mm1
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        add     rdi, 8
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pxor    mm5, mm0
        paddw   mm5, mm2                    ; and add to weight_AB
        pxor    mm5, mm0
        cmp     rdi, rsi
        jnz     buff_term_18_loop

        movq    [rbp+16], mm4               ; post-store samples_AB[0]
        jmp     bdone

        align  64

buff_term_minus_1_loop:
        movq    mm3, mm4                    ; mm3 = previous calculated value
        movq    mm2, [rdi]                  ; mm2 = left_right
        movq    mm4, mm2
        psrlq   mm4, 32
        punpckldq mm3, mm2                  ; mm3 = sam_AB

        movq    mm1, mm3
        paddd   mm1, mm1
        psrlw   mm1, 1
        pmaddwd mm1, mm5

        movq    mm0, mm3
        psrld   mm0, 15
        pmaddwd mm0, mm5

        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi], mm2                  ; store result
        pxor    mm1, mm1
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        add     rdi, 8
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pcmpeqd mm1, mm1
        psubd   mm1, mm7
        psubd   mm1, mm7
        psubd   mm1, mm0
        pxor    mm5, mm0
        paddw   mm5, mm1
        paddusw mm5, mm2                    ; and add to weight_AB
        psubw   mm5, mm1
        pxor    mm5, mm0
        cmp     rdi, rsi
        jnz     buff_term_minus_1_loop

        movq    [rbp+16], mm4               ; post-store samples_AB[0]
        jmp     bdone

        align  64

buff_term_minus_2_loop:
        movq    mm2, [rdi]                  ; mm2 = left_right
        movq    mm3, mm2
        psrlq   mm3, 32
        por     mm3, mm4
        punpckldq mm4, mm2

        movq    mm1, mm3
        paddd   mm1, mm1
        psrlw   mm1, 1
        pmaddwd mm1, mm5

        movq    mm0, mm3
        psrld   mm0, 15
        pmaddwd mm0, mm5

        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi], mm2                  ; store result
        pxor    mm1, mm1
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        add     rdi, 8
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pcmpeqd mm1, mm1
        psubd   mm1, mm7
        psubd   mm1, mm7
        psubd   mm1, mm0
        pxor    mm5, mm0
        paddw   mm5, mm1
        paddusw mm5, mm2                    ; and add to weight_AB
        psubw   mm5, mm1
        pxor    mm5, mm0
        cmp     rdi, rsi
        jnz     buff_term_minus_2_loop

        movq    [rbp+16], mm4               ; post-store samples_AB[0]
        jmp     bdone

        align  64

buff_term_minus_3_loop:
        movq    mm2, [rdi]                  ; mm2 = left_right
        movq    mm3, mm4                    ; mm3 = previous calculated value
        movq    mm4, mm2                    ; mm0 = swap dwords of new data
        psrlq   mm4, 32
        punpckldq mm4, mm2                  ; mm3 = sam_AB

        movq    mm1, mm3
        paddd   mm1, mm1
        psrlw   mm1, 1
        pmaddwd mm1, mm5

        movq    mm0, mm3
        psrld   mm0, 15
        pmaddwd mm0, mm5

        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi], mm2                  ; store result
        pxor    mm1, mm1
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        add     rdi, 8
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pcmpeqd mm1, mm1
        psubd   mm1, mm7
        psubd   mm1, mm7
        psubd   mm1, mm0
        pxor    mm5, mm0
        paddw   mm5, mm1
        paddusw mm5, mm2                    ; and add to weight_AB
        psubw   mm5, mm1
        pxor    mm5, mm0
        cmp     rdi, rsi
        jnz     buff_term_minus_3_loop

        movq    [rbp+16], mm4               ; post-store samples_AB[0]

bdone:  pslld   mm5, 16                     ; sign-extend 16-bit weights back to dwords
        psrad   mm5, 16
        movq    [rbp+8], mm5                ; put weight_AB back

        ; convert samples_AB array back into samples_A and samples_B

        movq    mm0, [rbp+16]
        movq    mm1, [rbp+24]
        movq    mm2, [rbp+32]
        movq    mm3, [rbp+40]
        movq    mm4, [rbp+48]
        movq    mm5, [rbp+56]
        movq    mm6, [rbp+64]
        movq    mm7, [rbp+72]

        movd    DWORD PTR [rbp+16], mm0
        movd    DWORD PTR [rbp+20], mm1
        movd    DWORD PTR [rbp+24], mm2
        movd    DWORD PTR [rbp+28], mm3
        movd    DWORD PTR [rbp+32], mm4
        movd    DWORD PTR [rbp+36], mm5
        movd    DWORD PTR [rbp+40], mm6
        movd    DWORD PTR [rbp+44], mm7

        punpckhdq   mm0, mm0
        punpckhdq   mm1, mm1
        punpckhdq   mm2, mm2
        punpckhdq   mm3, mm3
        punpckhdq   mm4, mm4
        punpckhdq   mm5, mm5
        punpckhdq   mm6, mm6
        punpckhdq   mm7, mm7

        movd    DWORD PTR [rbp+48], mm0
        movd    DWORD PTR [rbp+52], mm1
        movd    DWORD PTR [rbp+56], mm2
        movd    DWORD PTR [rbp+60], mm3
        movd    DWORD PTR [rbp+64], mm4
        movd    DWORD PTR [rbp+68], mm5
        movd    DWORD PTR [rbp+72], mm6
        movd    DWORD PTR [rbp+76], mm7

        emms

        add     rsp, 8
        pop     rsi
        pop     rdi
        pop     rbx
        pop     rbp
        ret

pack_decorr_stereo_pass_x64win endp

; These are assembly optimized version of the following WavPack functions:
;
; void pack_decorr_stereo_pass_cont (
;   struct decorr_pass *dpp,
;   int32_t *in_buffer,
;   int32_t *out_buffer,
;   int32_t sample_count);
;
; void pack_decorr_stereo_pass_cont_rev (
;   struct decorr_pass *dpp,
;   int32_t *in_buffer,
;   int32_t *out_buffer,
;   int32_t sample_count);
;
; It performs a single pass of stereo decorrelation, transfering from the
; input buffer to the output buffer. Note that this version of the function
; requires that the up to 8 previous (depending on dpp->term) stereo samples
; are visible and correct. In other words, it ignores the "samples_*"
; fields in the decorr_pass structure and gets the history data directly
; from the source buffer. It does, however, return the appropriate history
; samples to the decorr_pass structure before returning.
;
; This is written to work on an X86-64 processor (also called the AMD64)
; running in 64-bit mode and uses the MMX extensions to improve the
; performance by processing both stereo channels together. It is based on
; the original MMX code written by Joachim Henke that used MMX intrinsics
; called from C. Many thanks to Joachim for that!
;
; This version is for 64-bit Windows. Note that the two public functions
; are "leaf" functions that simply load rax with the direction and jump
; into the private common "frame" function. The arguments are passed in
; registers:
;
;   struct decorr_pass *dpp     rcx
;   int32_t *in_buffer          rdx
;   int32_t *out_buffer         r8
;   int32_t sample_count        r9d
;
; During the processing loops, the following registers are used:
;
;   rdi         input buffer pointer
;   rsi         direction (-8 forward, +8 reverse)
;   rbx         delta from input to output buffer
;   ecx         sample count
;   rdx         sign (dir) * term * -8 (terms 1-8 only)
;   mm0, mm1    scratch
;   mm2         original sample values
;   mm3         correlation samples
;   mm4         weight sums
;   mm5         weights
;   mm6         delta
;   mm7         512 (for rounding)
;
; stack usage:
;
; [rsp+0] = *dpp
;

pack_decorr_stereo_pass_cont_rev_x64win:
        mov     rax, 8                      ; get value for reverse direction & jump
        jmp     pack_decorr_stereo_pass_cont_common

pack_decorr_stereo_pass_cont_x64win:
        mov     rax, -8                     ; get value for forward direction & jump
        jmp     pack_decorr_stereo_pass_cont_common

pack_decorr_stereo_pass_cont_common proc frame
        push_reg    rbp                     ; save non-volatile registers on stack
        push_reg    rbx                     ; (alphabetically)
        push_reg    rdi
        push_reg    rsi
        alloc_stack 8                       ; allocate 8 bytes on stack & align to 16 bytes
        end_prologue

        mov     [rsp], rcx                  ; [rsp] = *dpp
        mov     rdi, rcx                    ; copy params from win regs to Linux regs
        mov     rsi, rdx                    ; so we can leave following code similar
        mov     rdx, r8
        mov     rcx, r9

        mov     rdi, rsi                    ; rdi = inbuffer
        mov     rsi, rax                    ; rsi = -direction

        mov     eax, 512
        movd    mm7, eax
        punpckldq mm7, mm7                  ; mm7 = round (512)

        mov     rax, [rsp]                  ; access dpp
        mov     eax, [rax+4]
        movd    mm6, eax
        punpckldq mm6, mm6                  ; mm6 = delta (0-7)

        mov     rax, [rsp]                  ; access dpp
        movq    mm5, [rax+8]                ; mm5 = weight_AB
        movq    mm4, [rax+88]               ; mm4 = sum_AB

        mov     rbx, rdx                    ; rbx = out_buffer (rdx) - in_buffer (rdi)
        sub     rbx, rdi

        mov     rax, [rsp]                  ; *eax = dpp
        movsxd  rax, DWORD PTR [rax]        ; get term and vector to correct loop
        cmp     al, 17
        je      term_17_loop
        cmp     al, 18
        je      term_18_loop
        cmp     al, -1
        je      term_minus_1_loop
        cmp     al, -2
        je      term_minus_2_loop
        cmp     al, -3
        je      term_minus_3_loop

        sal     rax, 3
        mov     rdx, rax                    ; rdx = term * 8 to index correlation sample
        test    rsi, rsi                    ; test direction
        jns     default_term_loop
        neg     rdx
        jmp     default_term_loop

        align  64

default_term_loop:
        movq    mm3, [rdi+rdx]              ; mm3 = sam_AB

        movq    mm1, mm3
        pslld   mm1, 17
        psrld   mm1, 17
        pmaddwd mm1, mm5

        movq    mm0, mm3
        pslld   mm0, 1
        psrld   mm0, 16
        pmaddwd mm0, mm5

        movq    mm2, [rdi]                  ; mm2 = left_right
        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi+rbx], mm2              ; store result
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        sub     rdi, rsi
        pxor    mm1, mm1                    ; mm1 = zero
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pxor    mm5, mm0
        paddd   mm5, mm2                    ; and add to weight_AB
        pxor    mm5, mm0
        paddd   mm4, mm5                    ; add weights to sum
        dec     ecx
        jnz     default_term_loop

        mov     rax, [rsp]                  ; access dpp
        movq    [rax+8], mm5                ; put weight_AB back
        movq    [rax+88], mm4               ; put sum_AB back
        emms

        mov     rdx, [rsp]                  ; access dpp with rdx
        movsxd  rcx, DWORD PTR [rdx]        ; rcx = dpp->term

default_store_samples:
        dec     rcx
        add     rdi, rsi                    ; back up one full sample
        mov     eax, [rdi+4]
        mov     [rdx+rcx*4+48], eax         ; store samples_B [ecx]
        mov     eax, [rdi]
        mov     [rdx+rcx*4+16], eax         ; store samples_A [ecx]
        test    rcx, rcx
        jnz     default_store_samples
        jmp     done

        align  64

term_17_loop:
        movq    mm3, [rdi+rsi]              ; get previous calculated value
        paddd   mm3, mm3
        psubd   mm3, [rdi+rsi*2]

        movq    mm1, mm3
        pslld   mm1, 17
        psrld   mm1, 17
        pmaddwd mm1, mm5

        movq    mm0, mm3
        pslld   mm0, 1
        psrld   mm0, 16
        pmaddwd mm0, mm5

        movq    mm2, [rdi]                  ; mm2 = left_right
        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi+rbx], mm2              ; store result
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        sub     rdi, rsi
        pxor    mm1, mm1                    ; mm1 = zero
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pxor    mm5, mm0
        paddd   mm5, mm2                    ; and add to weight_AB
        pxor    mm5, mm0
        paddd   mm4, mm5                    ; add weights to sum
        dec     ecx
        jnz     term_17_loop

        mov     rax, [rsp]                  ; access dpp
        movq    [rax+8], mm5                ; put weight_AB back
        movq    [rax+88], mm4               ; put sum_AB back
        emms
        jmp     term_1718_common_store

        align  64

term_18_loop:
        movq    mm3, [rdi+rsi]              ; get previous calculated value
        movq    mm0, mm3
        psubd   mm3, [rdi+rsi*2]
        psrad   mm3, 1
        paddd   mm3, mm0                    ; mm3 = sam_AB

        movq    mm1, mm3
        pslld   mm1, 17
        psrld   mm1, 17
        pmaddwd mm1, mm5

        movq    mm0, mm3
        pslld   mm0, 1
        psrld   mm0, 16
        pmaddwd mm0, mm5

        movq    mm2, [rdi]                  ; mm2 = left_right
        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi+rbx], mm2              ; store result
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        sub     rdi, rsi
        pxor    mm1, mm1                    ; mm1 = zero
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pxor    mm5, mm0
        paddd   mm5, mm2                    ; and add to weight_AB
        pxor    mm5, mm0
        dec     ecx
        paddd   mm4, mm5                    ; add weights to sum
        jnz     term_18_loop

        mov     rax, [rsp]                  ; access dpp
        movq    [rax+8], mm5                ; put weight_AB back
        movq    [rax+88], mm4               ; put sum_AB back
        emms

term_1718_common_store:

        mov     rax, [rsp]                  ; access dpp
        add     rdi, rsi                    ; back up a full sample
        mov     edx, [rdi+4]                ; dpp->samples_B [0] = iptr [-1];
        mov     [rax+48], edx
        mov     edx, [rdi]                  ; dpp->samples_A [0] = iptr [-2];
        mov     [rax+16], edx
        add     rdi, rsi                    ; back up another sample
        mov     edx, [rdi+4]                ; dpp->samples_B [1] = iptr [-3];
        mov     [rax+52], edx
        mov     edx, [rdi]                  ; dpp->samples_A [1] = iptr [-4];
        mov     [rax+20], edx
        jmp     done

        align  64

term_minus_1_loop:
        movq    mm3, [rdi+rsi]              ; mm3 = previous calculated value
        movq    mm2, [rdi]                  ; mm2 = left_right
        psrlq   mm3, 32
        punpckldq mm3, mm2                  ; mm3 = sam_AB

        movq    mm1, mm3
        pslld   mm1, 17
        psrld   mm1, 17
        pmaddwd mm1, mm5

        movq    mm0, mm3
        pslld   mm0, 1
        psrld   mm0, 16
        pmaddwd mm0, mm5

        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi+rbx], mm2              ; store result
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        sub     rdi, rsi
        pxor    mm1, mm1                    ; mm1 = zero
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pcmpeqd mm1, mm1
        psubd   mm1, mm7
        psubd   mm1, mm7
        psubd   mm1, mm0
        pxor    mm5, mm0
        paddd   mm5, mm1
        paddusw mm5, mm2                    ; and add to weight_AB
        psubd   mm5, mm1
        pxor    mm5, mm0
        paddd   mm4, mm5                    ; add weights to sum
        dec     ecx
        jnz     term_minus_1_loop

        mov     rax, [rsp]                  ; access dpp
        movq    [rax+8], mm5                ; put weight_AB back
        movq    [rax+88], mm4               ; put sum_AB back
        emms

        add     rdi, rsi                    ; back up a full sample
        mov     edx, [rdi+4]                ; dpp->samples_A [0] = iptr [-1];
        mov     rax, [rsp]
        mov     [rax+16], edx
        jmp     done

        align  64

term_minus_2_loop:
        movq    mm2, [rdi]                  ; mm2 = left_right
        movq    mm3, mm2                    ; mm3 = swap dwords
        psrlq   mm3, 32
        punpckldq mm3, [rdi+rsi]            ; mm3 = sam_AB

        movq    mm1, mm3
        pslld   mm1, 17
        psrld   mm1, 17
        pmaddwd mm1, mm5

        movq    mm0, mm3
        pslld   mm0, 1
        psrld   mm0, 16
        pmaddwd mm0, mm5

        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi+rbx], mm2              ; store result
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        sub     rdi, rsi
        pxor    mm1, mm1                    ; mm1 = zero
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pcmpeqd mm1, mm1
        psubd   mm1, mm7
        psubd   mm1, mm7
        psubd   mm1, mm0
        pxor    mm5, mm0
        paddd   mm5, mm1
        paddusw mm5, mm2                    ; and add to weight_AB
        psubd   mm5, mm1
        pxor    mm5, mm0
        paddd   mm4, mm5                    ; add weights to sum
        dec     ecx
        jnz     term_minus_2_loop

        mov     rax, [rsp]                  ; access dpp
        movq    [rax+8], mm5                ; put weight_AB back
        movq    [rax+88], mm4               ; put sum_AB back
        emms

        add     rdi, rsi                    ; back up a full sample
        mov     edx, [rdi]                  ; dpp->samples_B [0] = iptr [-2];
        mov     rax, [rsp]
        mov     [rax+48], edx
        jmp     done

        align  64

term_minus_3_loop:
        movq    mm0, [rdi+rsi]              ; mm0 = previous calculated value
        movq    mm3, mm0                    ; mm3 = swap dwords
        psrlq   mm3, 32
        punpckldq mm3, mm0                  ; mm3 = sam_AB

        movq    mm1, mm3
        pslld   mm1, 17
        psrld   mm1, 17
        pmaddwd mm1, mm5

        movq    mm0, mm3
        pslld   mm0, 1
        psrld   mm0, 16
        pmaddwd mm0, mm5

        movq    mm2, [rdi]                  ; mm2 = left_right
        pslld   mm0, 5
        paddd   mm1, mm7                    ; add 512 for rounding
        psrad   mm1, 10
        psubd   mm2, mm0
        psubd   mm2, mm1                    ; add shifted sums
        movq    mm0, mm3
        movq    [rdi+rbx], mm2              ; store result
        pxor    mm0, mm2
        psrad   mm0, 31                     ; mm0 = sign (sam_AB ^ left_right)
        sub     rdi, rsi
        pxor    mm1, mm1                    ; mm1 = zero
        pcmpeqd mm2, mm1                    ; mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    ; mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    ; mm2 = 1s if either was zero
        pandn   mm2, mm6                    ; mask delta with zeros check
        pcmpeqd mm1, mm1
        psubd   mm1, mm7
        psubd   mm1, mm7
        psubd   mm1, mm0
        pxor    mm5, mm0
        paddd   mm5, mm1
        paddusw mm5, mm2                    ; and add to weight_AB
        psubd   mm5, mm1
        pxor    mm5, mm0
        paddd   mm4, mm5                    ; add weights to sum
        dec     ecx
        jnz     term_minus_3_loop

        mov     rax, [rsp]                  ; access dpp
        movq    [rax+8], mm5                ; put weight_AB back
        movq    [rax+88], mm4               ; put sum_AB back
        emms

        add     rdi, rsi                    ; back up a full sample
        mov     edx, [rdi+4]                ; dpp->samples_A [0] = iptr [-1];
        mov     rax, [rsp]
        mov     [rax+16], edx
        mov     edx, [rdi]                  ; dpp->samples_B [0] = iptr [-2];
        mov     [rax+48], edx

done:   add     rsp, 8                      ; begin epilog by deallocating stack
        pop     rsi                         ; restore non-volatile registers & return
        pop     rdi
        pop     rbx
        pop     rbp
        ret

pack_decorr_stereo_pass_cont_common endp

; This is an assembly optimized version of the following WavPack function:
;
; void decorr_mono_buffer (int32_t *buffer,
;                          struct decorr_pass *decorr_passes,
;                          int32_t num_terms,
;                          int32_t sample_count)
;
; Decorrelate a buffer of mono samples, in place, as specified by the array
; of decorr_pass structures. Note that this function does NOT return the
; dpp->samples_X[] values in the "normalized" positions for terms 1-8, so if
; the number of samples is not a multiple of MAX_TERM, these must be moved if
; they are to be used somewhere else.
;
; By using the overflow detection of the multiply instruction, this detects
; when the "long_math" varient is required.
;
; This is written to work on an X86-64 processor (also called the AMD64)
; running in 64-bit mode. This version is for the 64-bit Windows ABI and
; provides appropriate prologs and epilogs for stack unwinding. The
; arguments are passed in registers:
;
;   int32_t *buffer             rcx
;   struct decorr_pass *dpp     rdx
;   int32_t num_terms           r8
;   int32_t sample_count        r9
;
; stack usage:
;
; [rsp+8] = sample_count
; [rsp+0] = decorr_passes
;
; register usage:
;
; ecx = sample being decorrelated
; esi = sample up counter
; rdi = *buffer
; rbp = *dpp
; r8 = dpp end ptr (general version only)
;

pack_decorr_mono_buffer_x64win proc public frame
        push_reg    rbp                     ; save non-volatile registers on stack
        push_reg    rbx                     ; (alphabetically)
        push_reg    rdi
        push_reg    rsi
        alloc_stack 24                      ; allocate 24 bytes on stack & align to 16 bytes
        end_prologue

        mov     rdi, rcx                    ; copy params from win regs to Linux regs
        mov     rsi, rdx                    ; so we can leave following code similar
        mov     rdx, r8
        mov     rcx, r9

        mov     [rsp+8], rcx                ; [rsp+8] = sample count
        mov     [rsp], rsi                  ; [rsp+0] = decorr_passes

        and     ecx, ecx                    ; test & handle zero sample count & zero term count
        jz      mexit
        and     edx, edx
        jz      mexit

        imul    rax, rdx, 96
        add     rax, rsi                     ; rax = terminating decorr_pass pointer
        mov     r8, rax
        mov     rbp, rsi
        xor     rsi, rsi                     ; up counter = 0
        jmp     decorrelate_loop

        align  64

decorrelate_loop:
        mov     ecx, [rdi+rsi*4]             ; ecx is the sample we're decorrelating
nxterm: mov     edx, [rbp]
        cmp     dl, 17
        jge     @f

        mov     eax, esi
        and     eax, 7
        mov     ebx, [rbp+16+rax*4]
        add     eax, edx
        and     eax, 7
        mov     [rbp+16+rax*4], ecx
        jmp     domult

        align  4
@@:     mov     edx, [rbp+16]
        mov     [rbp+16], ecx
        je      @f
        lea     ebx, [rdx+rdx*2]
        sub     ebx, [rbp+20]
        sar     ebx, 1
        mov     [rbp+20], edx
        jmp     domult

        align  4
@@:     lea     ebx, [rdx+rdx]
        sub     ebx, [rbp+20]
        mov     [rbp+20], edx

domult: mov     eax, [rbp+8]
        mov     edx, eax
        imul    eax, ebx
        jo      multov                      ; on overflow, jump to use 64-bit imul varient
        sar     eax, 10
        sbb     ecx, eax
        je      @f
        test    ebx, ebx
        je      @f
        xor     ebx, ecx
        sar     ebx, 31
        xor     edx, ebx
        add     edx, [rbp+4]
        xor     edx, ebx
        mov     [rbp+8], edx
@@:     add     rbp, 96
        cmp     rbp, r8
        jnz     nxterm

        mov     [rdi+rsi*4], ecx            ; store completed sample
        mov     rbp, [rsp]                  ; reload decorr_passes pointer to first term
        inc     esi                         ; increment sample index
        cmp     esi, [rsp+8]
        jnz     decorrelate_loop
        jmp     mexit

        align  4
multov: mov     eax, [rbp+8]
        imul    ebx
        shr     eax, 10
        sbb     ecx, eax
        shl     edx, 22
        sub     ecx, edx
        je      @f
        test    ebx, ebx
        je      @f
        xor     ebx, ecx
        sar     ebx, 31
        mov     eax, [rbp+8]
        xor     eax, ebx
        add     eax, [rbp+4]
        xor     eax, ebx
        mov     [rbp+8], eax
@@:     add     rbp, 96
        cmp     rbp, r8
        jnz     nxterm

        mov     [rdi+rsi*4], ecx            ; store completed sample
        mov     rbp, [rsp]                  ; reload decorr_passes pointer to first term
        inc     esi                         ; increment sample index
        cmp     esi, [rsp+8]
        jnz     decorrelate_loop            ; loop all the way back this time

mexit:  add     rsp, 24
        pop     rsi
        pop     rdi
        pop     rbx
        pop     rbp
        ret

pack_decorr_mono_buffer_x64win endp


; This is an assembly optimized version of the following WavPack function:
;
; void decorr_mono_pass_cont (int32_t *out_buffer,
;                             int32_t *in_buffer,
;                             struct decorr_pass *dpp,
;                             int32_t sample_count);
;
; It performs a single pass of mono decorrelation, transfering from the
; input buffer to the output buffer. Note that this version of the function
; requires that the up to 8 previous (depending on dpp->term) mono samples
; are visible and correct. In other words, it ignores the "samples_*"
; fields in the decorr_pass structure and gets the history data directly
; from the source buffer. It does, however, return the appropriate history
; samples to the decorr_pass structure before returning.
;
; By using the overflow detection of the multiply instruction, it detects
; when the "long_math" varient is required and automatically does it.
;
; This is written to work on an X86-64 processor (also called the AMD64)
; running in 64-bit mode. This version is for the 64-bit Windows ABI and
; provides appropriate prologs and epilogs for stack unwinding. The
; arguments are passed in registers:
;
;   int32_t *out_buffer         rcx
;   int32_t *in_buffer          rdx
;   struct decorr_pass *dpp     r8
;   int32_t sample_count        r9
;
; Stack usage:
;
; [rsp+0] = *dpp
;
; Register usage:
;
; rsi = source ptr
; rdi = destination ptr
; rcx = term * -4 (default terms)
; rcx = previous sample (terms 17 & 18)
; ebp = weight
; r8d = delta
; r9d = weight sum
; r10 = eptr
;

pack_decorr_mono_pass_cont_x64win proc public frame
        push_reg    rbp
        push_reg    rbx
        push_reg    rdi
        push_reg    rsi
        alloc_stack 8                       ; allocate 8 bytes on stack & align to 16 bytes
        end_prologue

        mov     rdi, rcx                    ; copy params from win regs to Linux regs
        mov     rsi, rdx                    ; so we can leave following code similar
        mov     rdx, r8
        mov     rcx, r9

        mov     [rsp], rdx
        and     ecx, ecx                    ; test & handle zero sample count
        jz      mono_done

        cld
        mov     r8d, [rdx+4]                ; rd8 = delta
        mov     ebp, [rdx+8]                ; ebp = weight
        mov     r9d, [rdx+88]               ; r9d = weight sum
        lea     r10, [rsi+rcx*4]            ; r10 = eptr
        mov     ecx, [rsi-4]                ; preload last sample
        mov     eax, [rdx]                  ; get term
        cmp     al, 17
        je      mono_term_17_loop
        cmp     al, 18
        je      mono_term_18_loop

        imul    rcx, rax, -4                ; rcx is index to correlation sample
        jmp     mono_default_term_loop

        align  64

mono_default_term_loop:
        mov     edx, [rsi+rcx]
        mov     ebx, edx
        imul    edx, ebp
        jo      over
        lodsd
        sar     edx, 10
        sbb     eax, edx
        jmp     @f
over:   mov     eax, ebx
        imul    ebp
        shl     edx, 22
        shr     eax, 10
        adc     edx, eax                    ; edx = apply_weight (sam_A)
        lodsd
        sub     eax, edx
@@:     stosd
        je      @f
        test    ebx, ebx
        je      @f
        xor     eax, ebx
        cdq
        xor     ebp, edx
        add     ebp, r8d
        xor     ebp, edx
@@:     add     r9d, ebp
        cmp     rsi, r10
        jnz     mono_default_term_loop

        mov     rdx, [rsp]                  ; rdx = *dpp
        mov     [rdx+8], ebp                ; put weight back
        mov     [rdx+88], r9d               ; put weight sum back
        movsxd  rcx, DWORD PTR [rdx]        ; rcx = dpp->term

mono_default_store_samples:
        dec     rcx
        sub     rsi, 4                      ; back up one sample
        mov     eax, [rsi]
        mov     [rdx+rcx*4+16], eax         ; store samples_A [ecx]
        test    rcx, rcx
        jnz     mono_default_store_samples
        jmp     mono_done

        align  64

mono_term_17_loop:
        lea     edx, [rcx+rcx]
        sub     edx, [rsi-8]                ; ebx = sam_A
        mov     ebx, edx
        imul    edx, ebp
        jo      over17
        sar     edx, 10
        lodsd
        mov     ecx, eax
        sbb     eax, edx
        jmp     @f
over17: mov     eax, ebx
        imul    ebp
        shl     edx, 22
        shr     eax, 10
        adc     edx, eax                    ; edx = apply_weight (sam_A)
        lodsd
        mov     ecx, eax
        sub     eax, edx
@@:     stosd
        je      @f
        test    ebx, ebx
        je      @f
        xor     eax, ebx
        cdq
        xor     ebp, edx
        add     ebp, r8d
        xor     ebp, edx
@@:     add     r9d, ebp
        cmp     rsi, r10
        jnz     mono_term_17_loop
        jmp     mono_term_1718_exit

        align  64

mono_term_18_loop:
        lea     edx, [rcx+rcx*2]
        sub     edx, [rsi-8]
        sar     edx, 1
        mov     ebx, edx                    ; ebx = sam_A
        imul    edx, ebp
        jo      over18
        sar     edx, 10
        lodsd
        mov     ecx, eax
        sbb     eax, edx
        jmp     @f
over18: mov     eax, ebx
        imul    ebp
        shl     edx, 22
        shr     eax, 10
        adc     edx, eax                    ; edx = apply_weight (sam_A)
        lodsd
        mov     ecx, eax
        sub     eax, edx
@@:     stosd
        je      @f
        test    ebx, ebx
        je      @f
        xor     eax, ebx
        cdq
        xor     ebp, edx
        add     ebp, r8d
        xor     ebp, edx
@@:     add     r9d, ebp
        cmp     rsi, r10
        jnz     mono_term_18_loop

mono_term_1718_exit:
        mov     rdx, [rsp]                  ; rdx = *dpp
        mov     [rdx+8], ebp                ; put weight back
        mov     [rdx+88], r9d               ; put weight sum back
        mov     eax, [rsi-4]                ; dpp->samples_A [0] = bptr [-1]
        mov     [rdx+16], eax
        mov     eax, [rsi-8]                ; dpp->samples_A [1] = bptr [-2]
        mov     [rdx+20], eax

mono_done:
        add     rsp, 8
        pop     rsi
        pop     rdi
        pop     rbx
        pop     rbp
        ret

pack_decorr_mono_pass_cont_x64win endp


; This is an assembly optimized version of the following WavPack function:
;
; uint32_t log2buffer (int32_t *samples, uint32_t num_samples, int limit);
;
; This function scans a buffer of 32-bit ints and accumulates the total
; log2 value of all the samples. This is useful for determining maximum
; compression because the bitstream storage required for entropy coding
; is proportional to the base 2 log of the samples.
;
; This is written to work on an X86-64 processor (also called the AMD64)
; running in 64-bit mode. This version is for the 64-bit Windows ABI and
; provides appropriate prologs and epilogs for stack unwinding. The
; arguments are passed in registers:
;
;   int32_t *samples            rcx
;   uint32_t num_samples        rdx
;   int limit                   r8
;
; During the processing loops, the following registers are used:
;
;   r8              pointer to the 256-byte log fraction table
;   rsi             input buffer pointer
;   edi             sum accumulator
;   ebx             sample count
;   ebp             limit (if specified non-zero)
;   eax,ecx,edx     scratch
;

        align  256

        .radix 16

log2_table:
        byte   000, 001, 003, 004, 006, 007, 009, 00a, 00b, 00d, 00e, 010, 011, 012, 014, 015
        byte   016, 018, 019, 01a, 01c, 01d, 01e, 020, 021, 022, 024, 025, 026, 028, 029, 02a
        byte   02c, 02d, 02e, 02f, 031, 032, 033, 034, 036, 037, 038, 039, 03b, 03c, 03d, 03e
        byte   03f, 041, 042, 043, 044, 045, 047, 048, 049, 04a, 04b, 04d, 04e, 04f, 050, 051
        byte   052, 054, 055, 056, 057, 058, 059, 05a, 05c, 05d, 05e, 05f, 060, 061, 062, 063
        byte   064, 066, 067, 068, 069, 06a, 06b, 06c, 06d, 06e, 06f, 070, 071, 072, 074, 075
        byte   076, 077, 078, 079, 07a, 07b, 07c, 07d, 07e, 07f, 080, 081, 082, 083, 084, 085
        byte   086, 087, 088, 089, 08a, 08b, 08c, 08d, 08e, 08f, 090, 091, 092, 093, 094, 095
        byte   096, 097, 098, 099, 09a, 09b, 09b, 09c, 09d, 09e, 09f, 0a0, 0a1, 0a2, 0a3, 0a4
        byte   0a5, 0a6, 0a7, 0a8, 0a9, 0a9, 0aa, 0ab, 0ac, 0ad, 0ae, 0af, 0b0, 0b1, 0b2, 0b2
        byte   0b3, 0b4, 0b5, 0b6, 0b7, 0b8, 0b9, 0b9, 0ba, 0bb, 0bc, 0bd, 0be, 0bf, 0c0, 0c0
        byte   0c1, 0c2, 0c3, 0c4, 0c5, 0c6, 0c6, 0c7, 0c8, 0c9, 0ca, 0cb, 0cb, 0cc, 0cd, 0ce
        byte   0cf, 0d0, 0d0, 0d1, 0d2, 0d3, 0d4, 0d4, 0d5, 0d6, 0d7, 0d8, 0d8, 0d9, 0da, 0db
        byte   0dc, 0dc, 0dd, 0de, 0df, 0e0, 0e0, 0e1, 0e2, 0e3, 0e4, 0e4, 0e5, 0e6, 0e7, 0e7
        byte   0e8, 0e9, 0ea, 0ea, 0eb, 0ec, 0ed, 0ee, 0ee, 0ef, 0f0, 0f1, 0f1, 0f2, 0f3, 0f4
        byte   0f4, 0f5, 0f6, 0f7, 0f7, 0f8, 0f9, 0f9, 0fa, 0fb, 0fc, 0fc, 0fd, 0fe, 0ff, 0ff

        .radix  10

log2buffer_x64win proc public frame
        push_reg    rbp                     ; save non-volatile registers on stack
        push_reg    rbx                     ; (alphabetically)
        push_reg    rdi
        push_reg    rsi
        alloc_stack 8                       ; allocate 8 bytes on stack & align to 16 bytes
        end_prologue

        mov     rdi, rcx                    ; copy params from win regs to Linux regs
        mov     rsi, rdx                    ; so we can leave following code similar
        mov     rdx, r8

        mov     ebx, esi                    ; ebx = num_samples
        mov     rsi, rdi                    ; rsi = *samples
        xor     edi, edi                    ; initialize sum
        lea     r8, log2_table
        test    ebx, ebx                    ; test count for zero
        jz      normal_exit
        mov     ebp, edx                    ; ebp = limit
        test    ebp, ebp                    ; we have separate loops for limit and no limit
        jz      no_limit_loop
        jmp     limit_loop

        align  64

limit_loop:
        mov     eax, [rsi]                  ; get next sample into eax
        cdq                                 ; edx = sign of sample (for abs)
        add     rsi, 4
        xor     eax, edx
        sub     eax, edx
        je      L40                         ; skip if sample was zero
        mov     edx, eax                    ; move to edx and apply rounding
        shr     eax, 9
        add     edx, eax
        bsr     ecx, edx                    ; ecx = MSB set in sample (0 - 31)
        lea     eax, [ecx+1]                ; eax = number used bits in sample (1 - 32)
        sub     ecx, 8                      ; ecx = shift right amount (-8 to 23)
        ror     edx, cl                     ; use rotate to do "signed" shift 
        sal     eax, 8                      ; move nbits to integer portion of log
        movzx   edx, dl                     ; dl = mantissa, look up log fraction in table 
        mov     al, [r8+rdx]                ; eax = combined integer and fraction for full log
        add     edi, eax                    ; add to running sum and compare to limit
        cmp     eax, ebp
        jge     limit_exceeded
L40:    sub     ebx, 1                      ; loop back if more samples
        jne     limit_loop
        jmp     normal_exit

        align  64

no_limit_loop:
        mov     eax, [rsi]                  ; get next sample into eax
        cdq                                 ; edx = sign of sample (for abs)
        add     rsi, 4
        xor     eax, edx
        sub     eax, edx
        je      L45                         ; skip if sample was zero
        mov     edx, eax                    ; move to edx and apply rounding
        shr     eax, 9
        add     edx, eax
        bsr     ecx, edx                    ; ecx = MSB set in sample (0 - 31)
        lea     eax, [ecx+1]                ; eax = number used bits in sample (1 - 32)
        sub     ecx, 8                      ; ecx = shift right amount (-8 to 23)
        ror     edx, cl                     ; use rotate to do "signed" shift 
        sal     eax, 8                      ; move nbits to integer portion of log
        movzx   edx, dl                     ; dl = mantissa, look up log fraction in table 
        mov     al, [r8+rdx]                ; eax = combined integer and fraction for full log
        add     edi, eax                    ; add to running sum
L45:    sub     ebx, 1
        jne     no_limit_loop
        jmp     normal_exit

limit_exceeded:
        mov     edi, -1                     ; return -1 to indicate limit hit
normal_exit:
        mov     eax, edi                    ; move sum accumulator into eax for return

        add     rsp, 8                      ; begin epilog by deallocating stack
        pop     rsi                         ; restore non-volatile registers & return
        pop     rdi
        pop     rbx
        pop     rbp
        ret

log2buffer_x64win endp

asmcode ends

        end

