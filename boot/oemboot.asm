;
; File:
;                          oemboot.asm
;                      2004, Kenneth J. Davis
;                Copyright (c) 200?, <add name here>
; Description:
; OEM boot sector for FreeDOS compatible with IBM's (R) PC-DOS,
; and Microsoft's (R) PC-DOS.  It may work with OpenDOS/DR-DOS,
; although the standard FreeDOS boot sector works with later
; releases.  May work with other versions of DOS that use
; IBMBIO.COM/IBMDOS.COM pair.  This boot sector loads only up
; to 58 sectors (29KB) of the kernel (IBMBIO.COM) to 0x70:0 then
; jumps to it.  As best I can tell, PC-DOS (and assuming MS-DOS
; behaves similar) expects on entry for:
; ch = media id byte in the boot sector
; dl = BIOS drive booted from (0x00=A:, 0x80=C:, ...)
; ax:bx = the LBA sector of 1st data sector 0x0000:0021 for FAT12
; ?or? 1st sector of IBMBIO.COM (which is normally 1st data sector)
; it also expects the boot sector (in particular the BPB)
; to still be at 0x0:7C00, the directory entry for IBMBIO.COM
; (generally first entry of first sector of the root directory)
; at 0x50:0 (DOS Data Area).  The original boot sector may update
; the floppy disk parameter table (int 1Eh), but we don't so
; may fail for any systems where the changes (???) are needed.
; If the above conditions are not met, then IBMBIO.COM will
; print the not a bootable disk error message.
;
; This boot sector only supports FAT12/FAT16 as PC-DOS
; does not support FAT32 and newer FAT32 capable DOSes
; probably have different boot requirements; also do NOT
; use it to boot the FreeDOS kernel as it expects to be
; fully loaded by boot sector (> 29KB & usually to 0x60:0).
;
; WARNING: PC-DOS has additional requirements, in particular,
; it may expect that IBMBIO.COM and IBMDOS.COM be the 1st
; two entries in the root directory (even before the label)
; and that they occupy the 1st consecutive data sectors.
; Newer releases may support other positions, but still
; generally should occupy consecutive sectors. These conditions
; can usually be met by running sys on a freshly formatted
; and un-label'd disk.
;
;
; Derived From:
;                            boot.asm
;                           DOS-C boot
;
;                   Copyright (c) 1997, 2000-2004
;               Svante Frey, Jim Hall, Jim Tabor, Bart Oldeman,
;             Tom Ehlert, Eric Auer, Luchezar Georgiev, Jon Gentle
;             and Michal H. Tyc (DR-DOS adaptation, boot26dr.asm)
;                      All Rights Reserved
;
; This file is part of FreeDOS.
;
; DOS-C is free software; you can redistribute it and/or
; modify it under the terms of the GNU General Public License
; as published by the Free Software Foundation; either version
; 2, or (at your option) any later version.
;
; DOS-C is distributed in the hope that it will be useful, but
; WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See
; the GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public
; License along with DOS-C; see the file COPYING.  If not,
; write to the Free Software Foundation, 675 Mass Ave,
; Cambridge, MA 02139, USA.
;
;
;	+--------+
;	| CLUSTER|
;	|  LIST  |
;	|--------| 0000:7F00
;     |LBA PKT |
;	|--------| 0000:7E00  (0:BP+200)
;	|BOOT SEC| contains BPB
;	|ORIGIN  | 
;	|--------| 0000:7C00  (0:BP)
;	|STACK   | minimal 256 bytes (1/2 sector)
;	|- - - - |
;	|KERNEL  | kernel loaded here (max 58 sectors, 29KB)
;	|LOADED  | also used as FAT buffer
;	|--------| 0070:0000 (0:0700)
;	|DOS DA/ | DOS Data Area,
;	|ROOT DIR| during boot the 1st sector of root directory
;	|--------| 0000:0500
;	|BDA     | BIOS Data Area
;	+--------+ 0000:0400
;	|IVT     | Interrupt Vector Table
;	+--------+ 0000:0000


;%define ISFAT12         1              ; only 1 of these should be set,
;%define ISFAT16         1              ; defines which FAT is supported

%define TRYLBAREAD       1              ; undefine to use only CHS int 13h
;%define LOOPONERR       1              ; if defined on error simply loop forever
;%define SETROOTDIR      1              ; if defined dir entry copied to 0:500
;%define RETRYALWAYS     1              ; if defined retries read forever
;%define FORCEBIOSDRV    1              ; if defined always use boot drive from BIOS
;%define MSCOMPAT        1              ; sets default filename to MSDOS IO.SYS

segment	.text

%define BASE            0x7c00          ; boot sector originally at 0x0:BASE
%define LOADSEG         0x0070          ; segment to load kernel at LOADSEG:0
%define LOADEND         0x07b0          ; limit reads to below this segment
                                        ; LOADSEG+29KB, else data overwritten

%define FATBUF          bp-0x7500       ; offset of temporary buffer for FAT
                                        ; chain 0:FATBUF = 0:0700 = LOADSEG:0
%define ROOTDIR         bp-0x7700       ; offset to buffer for root directory
                                        ; entry of kernel 0:ROOTDIR
%define CLUSTLIST       bp+0x0300       ; zero terminated list of clusters
                                        ; that the kernel occupies

;       Some extra variables
; using bp-Entry+variable_name generates smaller code than using just
; variable_name, where bp is initialized to Entry, so bp-Entry equals 0

%define LBA_PACKET      bp+0x0200            ; immediately after boot sector
%define LBA_SIZE        word [LBA_PACKET]    ; size of packet, should be 10h
%define LBA_SECNUM      word [LBA_PACKET+2]  ; number of sectors to read
%define LBA_OFF         LBA_PACKET+4         ; buffer to read/write to
%define LBA_SEG         LBA_PACKET+6
%define LBA_SECTOR_0    word [LBA_PACKET+8 ] ; LBA starting sector #
%define LBA_SECTOR_16   word [LBA_PACKET+10]
%define LBA_SECTOR_32   word [LBA_PACKET+12]
%define LBA_SECTOR_48   word [LBA_PACKET+14]

%define PARAMS LBA_PACKET+0x10
;%define RootDirSecs      PARAMS+0x0        ; # of sectors root dir uses
%define fat_start        PARAMS+0x2         ; first FAT sector
;%define root_dir_start   PARAMS+0x6        ; first root directory sector
%define data_start       PARAMS+0x0a        ; first data sector

;-----------------------------------------------------------------------


                org     BASE

Entry:          jmp     short real_start
                nop

;       bp is initialized to 7c00h
%define bsOemName       bp+0x03      ; OEM label
%define bsBytesPerSec   bp+0x0b      ; bytes/sector
%define bsSecPerClust   bp+0x0d      ; sectors/allocation unit
%define bsResSectors    bp+0x0e      ; # reserved sectors
%define bsFATs          bp+0x10      ; # of fats
%define bsRootDirEnts   bp+0x11      ; # of root dir entries
%define bsSectors       bp+0x13      ; # sectors total in image
%define bsMedia         bp+0x15      ; media descrip: fd=2side9sec, etc...
%define sectPerFat      bp+0x16      ; # sectors in a fat
%define sectPerTrack    bp+0x18      ; # sectors/track
%define nHeads          bp+0x1a      ; # heads
%define nHidden         bp+0x1c      ; # hidden sectors
%define nSectorHuge     bp+0x20      ; # sectors if > 65536
%define drive           bp+0x24      ; drive number
%define extBoot         bp+0x26      ; extended boot signature
%define volid           bp+0x27
%define vollabel        bp+0x2b
%define filesys         bp+0x36


;-----------------------------------------------------------------------

;               times   0x3E-$+$$ db 0
;
;       Instead of zero-fill,
;       initialize BPB with values suitable for a 1440 K floppy
;
                db 'IBM  5.0'   ; OEM label
                dw 512          ; bytes per sector
                db 1            ; sectors per cluster
                dw 1            ; reserved sectors
                db 2            ; number of FATs
                dw 224          ; root directory entries
                dw 80 * 36      ; total sectors on disk
                db 0xF0         ; media descriptor
                dw 9            ; sectors per 1 FAT copy
                dw 18           ; sectors per track
                dw 2            ; number of heads
                dd 0            ; hidden sectors
                dd 0            ; big total sectors
                db 0            ; boot unit
                db 0            ; reserved
                db 0x29         ; extended boot record id
                dd 0x12345678   ; volume serial number
                db 'NO NAME    '; volume label
                db 'FAT12   '   ; filesystem id

;-----------------------------------------------------------------------
;   ENTRY
;-----------------------------------------------------------------------

real_start:
                cli             ; disable interrupts until stack ready
                cld             ; all string operations increment
                xor     ax, ax  ; ensure our segment registers ready
                mov     ds, ax  ; cs=ds=es=ss=0x0000
                mov     es, ax
                mov     ss, ax
                mov     bp, BASE
                lea     sp, [bp-2]

                                ; a reset should not be needed here
;               int     0x13    ; reset drive

;       For compatibility, diskette parameter vector updated.
;               lea     di  [bp+0x3E] ; just use bp for DR-DOS?
;               mov     bx, 4 * 1eh   ; stored at int 1E's vector
;               lds     si, [bx]      ; fetch current int 1eh pointer
;               mov     cl, 11        ; the parameter table is 11 bytes
;               rep     movsb         ; and copy the parameter block
;               mov     ds, ax        ; restore DS

                sti             ; enable interrupts
;
; Some BIOS don't pass drive number in DL, so don't use it if [drive] is known
;
%ifndef FORCEBIOSDRV
                cmp     byte [drive], 0xff ; impossible number written by SYS
                jne     dont_use_dl        ; was SYS drive: other than A or B?
%endif
                mov     [drive], dl        ; yes, rely on BIOS drive number in DL
dont_use_dl:                               ; no,  rely on [drive] written by SYS


;       GETDRIVEPARMS:  Calculate start of some disk areas.
;
                mov     si, word [nHidden]
                mov     di, word [nHidden+2]
                add     si, word [bsResSectors]
                adc     di, byte 0              ; DI:SI = first FAT sector

                mov     word [fat_start], si
                mov     word [fat_start+2], di

                mov     al, [bsFATs]
                cbw
                mul     word [sectPerFat]       ; DX:AX = total number of FAT sectors

                add     si, ax
                adc     di, dx                  ; DI:SI = first root directory sector
                push di                         ; mov word [root_dir_start+2], di
                push si                         ; mov word [root_dir_start], si

                ; Calculate how many sectors the root directory occupies.
                mov     bx, [bsBytesPerSec]
                mov     cl, 5                   ; divide BX by 32
                shr     bx, cl                  ; BX = directory entries per sector

                mov     ax, [bsRootDirEnts]
                xor     dx, dx
                div     bx                      ; set AX = sectors per root directory
                push    ax                      ; mov word [RootDirSecs], ax

                add     si, ax
                adc     di, byte 0              ; DI:SI = first data sector

                mov     [data_start], si
                mov     [data_start+2], di


;       FINDFILE: Searches for the file in the root directory.
;
;       Returns:
;                               AX = first cluster of file

                ; First, read the root directory into buffer.
                ; into the temporary buffer. (max 29KB or overruns stuff)

                pop     di              ; mov di, word [RootDirSecs]
                pop     ax              ; mov ax, word [root_dir_start]
                pop     dx              ; mov dx, word [root_dir_start+2]
                lea     bx, [ROOTDIR]   ; es:bx = 0:0500
                push    es              ; save pointer to ROOTDIR
                call    readDisk
                pop     es              ; restore pointer to ROOTDIR
                lea     si, [ROOTDIR]   ; ds:si = 0:0500


		; Search for kernel file name, and find start cluster.

next_entry:     mov     cx, 11
                mov     di, filename
                push    si
                repe    cmpsb
                pop     si
                mov     ax, [si+0x1A]; get cluster number from directory entry
                je      ffDone

                add     si, byte 0x20   ; go to next directory entry
                jc      near boot_error ; fail if not found and si wraps
                cmp     byte [si], 0    ; if the first byte of the name is 0,
                jnz     next_entry      ; there are no more files in the directory

ffDone:
                push    ax              ; store first cluster number

%ifdef SETROOTDIR
                ; copy over this portion of root dir to 0x0:500 for PC-DOS
                ; (this may allow IBMBIO.COM to start in any directory entry)
                lea     di, [ROOTDIR]   ; es:di = 0:0500
                mov     cx, 0x100
                rep     movsw
%endif


;       GETFATCHAIN:
;
;       Reads the FAT chain and stores it in a temporary buffer in the first
;       64 kb.  The FAT chain is stored an array of 16-bit cluster numbers,
;       ending with 0.
;
;       The file must fit in conventional memory, so it can't be larger than
;       640 kb. The sector size must be at least 512 bytes, so the FAT chain
;       can't be larger than 2.5 KB (655360 / 512 * 2 = 2560).
;
;       Call with:      AX = first cluster in chain

                ; Load the complete FAT into memory. The FAT can't be larger
                ; than 128 kb
                lea     bx, [FATBUF]            ; es:bx = 0:0700
                mov     di, [sectPerFat]
                mov     ax, word [fat_start]
                mov     dx, word [fat_start+2]
                call    readDisk

                ; Set ES:DI to the temporary storage for the FAT chain.
                push    ds
                pop     es
                lea     di, [CLUSTLIST]
                ; Set DS:0 to FAT data we loaded
                mov     ax, LOADSEG
                mov     ds, ax                  ; ds:0 = 0x70:0 = 0:FATBUF

                pop     ax                      ; restore first cluster number
                push    ds                      ; store LOADSEG

next_clust:     stosw                           ; store cluster number
                mov     si, ax                  ; SI = cluster number

%ifdef ISFAT12
                ; This is a FAT-12 disk.

fat_12:         add     si, si          ; multiply cluster number by 3...
                add     si, ax
                shr     si, 1           ; ...and divide by 2
                lodsw

                ; If the cluster number was even, the cluster value is now in
                ; bits 0-11 of AX. If the cluster number was odd, the cluster
                ; value is in bits 4-15, and must be shifted right 4 bits. If
                ; the number was odd, CF was set in the last shift instruction.

                jnc     fat_even
                mov     cl, 4
                shr     ax, cl

fat_even:       and     ah, 0x0f        ; mask off the highest 4 bits
                cmp     ax, 0x0ff8      ; check for EOF
                jb      next_clust      ; continue if not EOF

%endif
%ifdef ISFAT16
                ; This is a FAT-16 disk. The maximal size of a 16-bit FAT
                ; is 128 kb, so it may not fit within a single 64 kb segment.

fat_16:         mov     dx, LOADSEG
                add     si, si          ; multiply cluster number by two
                jnc     first_half      ; if overflow...
                add     dh, 0x10        ; ...add 64 kb to segment value

first_half:     mov     ds, dx          ; DS:SI = pointer to next cluster
                lodsw                   ; AX = next cluster

                cmp     ax, 0xfff8      ; >= FFF8 = 16-bit EOF
                jb      next_clust      ; continue if not EOF
%endif

finished:       ; Mark end of FAT chain with 0, so we have a single
                ; EOF marker for both FAT-12 and FAT-16 systems.

                xor     ax, ax
                stosw

                push    cs
                pop     ds


;       loadFile: Loads the file into memory, one cluster at a time.

                pop     es              ; set ES:BX to load address 70:0
                xor     bx, bx

                lea     si, [CLUSTLIST] ; set DS:SI to the FAT chain

cluster_next:   lodsw                   ; AX = next cluster to read
                or      ax, ax          ; EOF?
                jne     load_next       ; no, continue

                                        ; dl set to drive by readDisk
                mov ch, [bsMedia]       ; ch set to media id
                mov ax, [data_start+2]  ; ax:bx set to 1st data sector
                mov bx, [data_start]    ;
                jmp     LOADSEG:0000    ; yes, pass control to kernel

load_next:      dec     ax                      ; cluster numbers start with 2
                dec     ax

                mov     di, word [bsSecPerClust]
                and     di, 0xff                ; DI = sectors per cluster
                mul     di
                add     ax, [data_start]
                adc     dx, [data_start+2]      ; DX:AX = first sector to read
                call    readDisk
                jmp     short cluster_next


; shows text after the call to this function.

show:           pop     si
                lodsb                           ; get character
                push    si                      ; stack up potential return address
                mov     ah,0x0E                 ; show character
                int     0x10                    ; via "TTY" mode
                cmp     al,'.'                  ; end of string?
                jne     show                    ; until done
                ret

; failed to boot

boot_error:     
%ifdef LOOPONERR
jmp boot_error
%else
call            show
;                db      "Error! Hit a key to reboot."
                db      "Err."

                xor     ah,ah
                int     0x13                    ; reset floppy
                int     0x16                    ; wait for a key
                int     0x19                    ; reboot the machine
%endif


;       readDisk:       Reads a number of sectors into memory.
;
;       Call with:      DX:AX = 32-bit DOS sector number
;                       DI = number of sectors to read
;                       ES:BX = destination buffer
;
;       Returns:        CF set on error
;                       ES:BX points one byte after the last byte read.
;                       Exits early if LBA_SEG == LOADEND.

readDisk:       push    si                      ; preserve cluster #

                mov     LBA_SECTOR_0,ax
                mov     LBA_SECTOR_16,dx
                mov     word [LBA_SEG], es
                mov     word [LBA_OFF], bx

                call    show
                db      "."
read_next:

; initialize constants
                mov     LBA_SIZE, 10h           ; LBA packet is 16 bytes
                mov     LBA_SECNUM,1            ; reset LBA count if error

; limit kernel loading to 29KB, preventing stack & boot sector being overwritten
                cmp     word [LBA_SEG], LOADEND ; skip reading if past the end
                je      read_skip               ; of kernel file buffer

;******************** LBA_READ *******************************

						; check for LBA support
										
%ifdef TRYLBAREAD
                mov     ah,041h                 ;
                mov     bx,055aah               ;
                mov     dl, [drive]             ; BIOS drive, 0=A:, 80=C:
                test    dl,dl                   ; don't use LBA addressing on A:
                jz      read_normal_BIOS        ; might be a (buggy)
                                                ; CDROM-BOOT floppy emulation
                int     0x13
                jc	read_normal_BIOS

                shr     cx,1                    ; CX must have 1 bit set

                sbb     bx,0aa55h - 1           ; tests for carry (from shr) too!
                jne     read_normal_BIOS
                                                ; OK, drive seems to support LBA addressing
                lea     si,[LBA_PACKET]
                                                ; setup LBA disk block
                mov     LBA_SECTOR_32,bx        ; bx is 0 if extended 13h mode supported
                mov     LBA_SECTOR_48,bx
	

                mov     ah,042h
                jmp short    do_int13_read
%endif

							

read_normal_BIOS:      

;******************** END OF LBA_READ ************************
                mov     cx, LBA_SECTOR_0
                mov     dx, LBA_SECTOR_16

                ;
                ; translate sector number to BIOS parameters
                ;
                ;
                ; abs = sector                          offset in track
                ;     + head * sectPerTrack             offset in cylinder
                ;     + track * sectPerTrack * nHeads   offset in platter
                ;
                mov     al, [sectPerTrack]
                mul     byte [nHeads]
                xchg    ax, cx
                ; cx = nHeads * sectPerTrack <= 255*63
                ; dx:ax = abs
                div     cx
                ; ax = track, dx = sector + head * sectPertrack
                xchg    ax, dx
                ; dx = track, ax = sector + head * sectPertrack
                div     byte [sectPerTrack]
                ; dx =  track, al = head, ah = sector
                mov     cx, dx
                ; cx =  track, al = head, ah = sector

                ; the following manipulations are necessary in order to
                ; properly place parameters into registers.
                ; ch = cylinder number low 8 bits
                ; cl = 7-6: cylinder high two bits
                ;      5-0: sector
                mov     dh, al                  ; save head into dh for bios
                xchg    ch, cl                  ; set cyl no low 8 bits
                ror     cl, 1                   ; move track high bits into
                ror     cl, 1                   ; bits 7-6 (assumes top = 0)
                or      cl, ah                  ; merge sector into cylinder
                inc     cx                      ; make sector 1-based (1-63)

                les     bx,[LBA_OFF]
                mov     ax, 0x0201
do_int13_read:                
                mov     dl, [drive]
                int     0x13

read_finished:
%ifdef RETRYALWAYS
                jnc     read_ok                 ; jump if no error
                xor     ah, ah                  ; else, reset floppy
                int     0x13
read_next_chained:
                jmp     short read_next         ; read the same sector again
%else
                jc      boot_error              ; exit on error
%endif

read_ok:
                mov     ax, word [bsBytesPerSec]  
                shr     ax, 4                   ; adjust segment pointer by increasing
                add     word [LBA_SEG], ax      ; by paragraphs read in (per sector)

                add     LBA_SECTOR_0,  byte 1
                adc     LBA_SECTOR_16, byte 0   ; DX:AX = next sector to read
                dec     di                      ; if there is anything left to read,
%ifdef RETRYALWAYS
                jnz     read_next_chained       ; continue
%else
                jnz     read_next               ; continue
%endif

read_skip:
                mov     es, word [LBA_SEG]      ; load adjusted segment value
                ; clear carry: unnecessary since adc clears it
                pop     si
                ret

       times   0x01f1-$+$$ db 0
%ifdef MSCOMPAT
filename        db      "IO      SYS"
%else
filename        db      "IBMBIO  COM"
%endif
                db      0,0

sign            dw      0xAA55

