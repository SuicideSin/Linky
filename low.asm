;Low-level USB routines

 include "settings.inc"
 include "equates.inc" 
 SEGMENT Main
 GLOBALS ON

 EXTERN WaitTimerBms,putAtoHL_ExtraRAMPage,getAfromHL_ExtraRAMPage,DispHexA,WaitTimer20ms,WaitTimer40ms
 EXTERN WaitTimer100ms,SendControlDataIncoming,HandleUSBActivity,SendControlDataOutgoing,ClearControlBuffer
 EXTERN IPutC

IsInterruptMode:
;Returns Z set if using interrupts, or NZ if using "no interrupt" mode.
       ld a,(USBFlags)
       and 1
       ret

InitializeUSB_Peripheral:
;Initializes the USB controller in peripheral mode.
;Returns carry set if problems
       ;Hold the USB controller in reset
       xor a
       out (4Ch),a
       ;Disable 48MHz crystal, power down Toshiba PHY,
       ; and disable USB suspend interrupt
       ld a,2
       out (54h),a
       ;Set D- switches to default
       ld a,20h
       out (4Ah),a
       ;Enable the various clocks we need
       call SetupClocks
       ;Release USB controller reset and enable protocol interrupts
       ld a,1
       out (5Bh),a
       ld a,8
       out (4Ch),a
       ;Wait until IP clock is enabled
       ld de,DEFAULT_TIMEOUT
$$:    call DecrementCounter
       ;TODO: This needs to go to an error routine instead
       scf
       ret z
       in a,(4Ch)
       res 6,a ;don't care about charge pump setting
       cp 1Ah
       jr nz,$B
       ;Enable all pipes for input and output
       ld a,0FFh
       out (87h),a
       xor a
       out (92h),a ;not sure what this is or if it's necessary
       ld a,0Eh
       out (89h),a
       ;Set the protocol interrupt mask, fires when:
       ;      Bus is suspended
       ;      Bus reset occurs
       ld a,5
       out (8Bh),a
       ;I don't know for sure, but I think this tells the controller to drive VBus.
       in a,(81h)
       set 0,a
       out (81h),a
       ;Enable the bus suspend interrupt
       in a,(54h)
       set 0,a
       out (54h),a
WaitForFrameCounterStart:
       ld b,FRAME_COUNTER_TIMEOUT / DEFAULT_TIMEOUT
frameCounterLoop:
       ld de,DEFAULT_TIMEOUT
$$:    call DecrementCounter
       jr z,counterExpired
       in a,(8Ch)
       or a
       jr z,$B
       or a
       ret
counterExpired:
       djnz frameCounterLoop
       ;TODO: This needs to go to an error routine instead
       scf
       ret
SetupClocks:
 IFDEF TI84PCSE
       call SetGPIOPin6
 ENDIF
       ;Set up internal charge pump
       xor a
       out (4Bh),a
       in a,(3Ah)
       bit 3,a
       jr z,$F
       ;We have an external charge pump, so disable the internal one
       ld a,20h
       out (4Bh),a
$$:    ;Power down Toshiba PHY, disable USB suspend interrupt,
       ; and stop master 48MHz disable signal
       xor a
       out (54h),a
       ;Wait 10ms for the hardware to deal with that
       ld b,1
       call WaitTimerBms
       ;Enable 48MHz clock and take Toshiba PHY out of power down mode
       in a,(3Ah)
       bit 3,a
       jr z,$F
       ;We have an external charge pump, don't enable the internal one
       ld a,44h
       out (54h),a
$$:    ;But then we enable it anyway? This might be an OS bug carried over to here.
       ld a,0C4h
       out (54h),a
       ret

SetGPIOPin6:
;No idea what this does.
       ;Set GPIO output pin 6
       in a,(39h)
       or 40h
       out (39h),a
       in a,(3Ah)
       or 40h
       out (3Ah),a
       jr WaitTimer100ms

InitializeUSB_Host:
;Initializes the USB controller in host mode.
;Returns carry set if problems
 IFDEF TI84PCSE
       call SetGPIOPin6
 ENDIF
       ;Get out if controller is not reset or suspended, and IP clock is enabled
       in a,(4Ch)
       and 1Ah
       ret z
       ;Hold the controller in reset
       xor a
       out (4Ch),a
       ;Enable USB interrupts
       ld a,1
       out (5Bh),a
       xor a
       in a,(4Ch)
       ;Disable 48MHz crystal, power down Toshiba PHY,
       ; and disable USB suspend interrupt
       ld a,2
       out (54h),a
       ;Set D- switches to default
       ld a,20h
       out (4Ah),a
       ;Enable the various clocks we need
       call SetupClocks
iusbhStart:
       ld de,DEFAULT_TIMEOUT
$$:    call DecrementCounter
       ;TODO: This needs to go to an error routine instead
       scf
       ret z
       in a,(4Ch)
       bit 0,a
       jr nz,iusbhDone ;bus is suspended, apparently we should get out now
       ;Is IP clock enabled? (this is 1Ah/5Ah ignoring controller reset bit)
       res 6,a
       cp 12h
       jr nz,$B
       ;Yes, continue
       in a,(4Dh)
       bit 5,a
       jr z,$F
       ;We're the B device; request host control from the other device
       call RequestHostControl
       ret c
       ;Make sure we get B cable unplug and A cable plug-in events? OTG screwery...
       ld a,90h
       out (57h),a
       jr iusbhContinue
$$:    ;We're the A device; drive VBus (I think)
       call EnableHostMode
iusbhContinue:
       ;Enable all pipes for input/output
       ld a,0FFh
       out (87h),a
       xor a
       out (92h),a ;not sure what this is
       ld a,0Eh
       out (89h),a
       ;Enable miscellaneous interrupts:
       ;      0: Bus suspended
       ;      5: Something unplugged
       ;      7: Insufficient power
       ld a,0A1h
       out (8Bh),a
       ld de,DEFAULT_TIMEOUT
$$:    call DecrementCounter
       ;TODO: This needs to go to an error routine instead
       scf
       ret z
       in a,(81h)
       bit 6,a
       jr z,$B
       ;Is host bit set?
       in a,(8Fh)
       bit 2,a
       jr z,iusbhStart ;no, try again
       ;Wait for frame counter to start
       call WaitForFrameCounterStart
       ret c
       ;Finally, we are host (which can happen regardless of which cable is attached).
       xor a
       out (5Bh),a
       call ResetAddress
       ld a,1
       out (5Bh),a
iusbhDone:
       or a
       ret

EnableHostModeFromBDevice:
;Initiates an SRP request.
       in a,(3Ah)
       bit 3,a
       jr nz,ehmOld
       call WaitForVBusLow
       ret c
       ;Set external discharge timeout
       ld a,27h
       out (50h),a
       ;Clear GPIO pins 0 and 1, set GPIO pin 2
       in a,(3Ah)
       and 0FCh
       or 4
       out (3Ah),a
       ;Enable GPIO pins 0-2 for output
       in a,(39h)
       or 7
       out (39h),a
       ;Disable SRP timeout interrupt
       ;Enable external discharge and start SRP request
       in a,(4Fh)
       and 0BFh
       or 88h
       out (4Fh),a
       call WaitTimer20ms
       ;Disable external discharge and stop SRP request
       in a,(4Fh)
       and 37h
       out (4Fh),a
       ;Clear GPIO pins 0-2
       in a,(3Ah)
       and 0F8h
       out (3Ah),a
       ;Enable GPIO pins 0-2 for output
       in a,(39h)
       or 7
       out (39h),a
       ;Release controller reset
       ld a,8
       out (4Ch),a
       ;Drive VBus (I think)
       ld a,1
       out (8Fh),a
       ld b,2
ehmfbdLoop:
       ld de,DEFAULT_TIMEOUT
$$:    call DecrementCounter
       jr z,$F
       in a,(4Dh)
       bit 6,a
       jr z,$B
       ;Disable GPIO pins 0-2 for output
       in a,(39h)
       and 0F8h
       out (39h),a
       or a
       ret
$$:    djnz ehmfbdLoop
       scf
       ret
EnableHostMode:
;Enables host mode (sets the "host bit") while B device is connected.
       in a,(3Ah)
       bit 3,a
       jr nz,ehmNew ;use new method
ehmOld:;Release controller reset
       ld a,8
       out (4Ch),a
       ;I'm not sure what bit 5 of port 81h indicates...
       ld de,DEFAULT_TIMEOUT
$$:    call DecrementCounter
       ;TODO: This needs to go to an error routine instead
       scf
       ret z
       in a,(81h)
       bit 5,a
       jr nz,$B
       ;Drive VBus (I think)
       ld a,1
       out (8Fh),a
       jr WaitTimer20ms
ehmNew:
       call WaitForVBusLow
       ret c
       ;Clear GPIO pins 0 and 1
       in a,(3Ah)
       and 0FDh
       out (3Ah),a
       ;Enable output on GPIO pin 1
       in a,(39h)
       or 2
       out (39h),a
       ;Release controller reset
       ld a,8
       out (4Ch),a
       ;Drive VBus (I think)
       ld a,1
       out (8Fh),a
       call WaitForVBusHigh
       ret c
       ;Disable output on GPIO pins 0 and 1
       in a,(39h)
       and 0FDh
       out (39h),a
       ret
RequestHostControl:
;Requests host control from the connected A device.
       call EnableHostModeFromBDevice
       ;TODO: This needs to go to an error routine instead
       ret c
       ;Disable all USB interrupts
       xor a
       out (5Bh),a
       out (8Bh),a
       ld b,50
       call WaitTimerBms
       ld a,3
       out (8Fh),a
       ;Enable all known miscellaneous interrupts
       ld a,0F7h
       out (8Bh),a
       ;Wait for new device to connect
       ld de,DEFAULT_TIMEOUT
$$:    call DecrementCounter
       ;TODO: This needs to go to an error routine instead
       scf
       ret z
       in a,(86h)
       bit 4,a
       jr z,$B
       call WaitTimer20ms
       in a,(81h)
       and 0F7h
       out (81h),a
       call ResetAddress
       in a,(8Fh)
       xor a
       ret
ResetAddress:
       ld a,8
       out (81h),a
       call WaitTimer20ms
       xor a
       out (81h),a
       call WaitTimer40ms
       xor a
       out (80h),a
       ret

GetDeviceDescriptor:
;Get device descriptor.
;Inputs:      B: page to store data
;             HL: address to store data
;             DE: number of bytes to retrieve
       call ClearControlBuffer
       ld hl,0680h
       ld (controlBuffer),hl
       ld a,01h
       ld (controlBuffer+3),a
       ld (controlBuffer+6),de
       ;Fall through to SendControlRequest
SendControlRequest:
;Issues control request with potential incoming/outgoing data.
;Inputs:      controlBuffer: SETUP data
;             B: page containing data to send/receive, if any
;             HL: address of data to send/receive, if any
;             DE: number of bytes to send or expected to receive
;Returns carry flag set if problems
       ld a,(controlBuffer)
       bit 7,a
       jr nz,SendControlRequest_DeviceToHost
       push de
       ld de,(controlBuffer+6)
       ld a,d
       or e
       pop de
       jr z,SendControlRequest_NoData
       ;Fall through to SendControlRequest_HostToDevice
SendControlRequest_HostToDevice:
;Issues control request with potential host->device data sent.
;Inputs:      B: page containing data to send, if any
;             HL: address of data to send, if any
;Returns carry flag set if problems
       ld de,(controlBuffer+6)
       call SendControlDataOutgoing
       ld de,DEFAULT_TIMEOUT
scrhtdWaitLoop:
       call DecrementCounter
       scf
       ret z
       call IsInterruptMode
       jr nz,$F
       ei
       halt
       jr scrhtdContinue
$$:    push de
       call HandleUSBActivity
       pop de
scrhtdContinue:
       ld hl,USBFlags
       bit sendingControlData,(hl)
       jr nz,scrhtdWaitLoop
       or a
       ret
SendControlRequest_DeviceToHost:
SendControlRequest_NoData:
;Issues control request with potential device->host data received.
;Inputs:      B: page to receive incoming data
;             HL: address to receive incoming data
;Outputs:     TODO: Bytes actually received
;Returns carry flag set if problems
       ld de,(controlBuffer+6)
       call SendControlDataIncoming
       ld de,DEFAULT_TIMEOUT
scrdthWaitLoop:
       call DecrementCounter
       scf
       ret z
       call IsInterruptMode
       jr nz,$F
       ei
       halt
       jr scrdthContinue
$$:    push de
       call HandleUSBActivity
       pop de
scrdthContinue:
       ld hl,USBFlags
       bit receivingControlDataHost,(hl)
       jr nz,scrdthWaitLoop
       or a
       ret

WaitForVBusLow:
       ;Wait for VBus to go low
       ld de,DEFAULT_TIMEOUT
$$:    call DecrementCounter
       ;TODO: This needs to go to an error routine instead
       scf
       ret z
       in a,(4Dh)
       bit 6,a
       jr nz,$B
       or a
       ret

WaitForVBusHigh:
       ;Wait for VBus to go high
       ld de,DEFAULT_TIMEOUT
$$:    call DecrementCounter
       ;TODO: This needs to go to an error routine instead
       scf
       ret z
       in a,(4Dh)
       bit 6,a
       jr z,$B
       or a
       ret

StallControlPipe:
;This is for peripheral mode only. 60h has a different meaning in host mode.
       xor a
       out (8Eh),a
       ld a,60h
       out (91h),a
       ret

FinishControlRequest:
;Yes, you need the dummy reads. Apparently.
       xor a
       out (8Eh),a
       in a,(91h)
       ld a,48h
       out (91h),a
       in a,(91h)
       ret

;------------------------------------------------------------------------------

SetupOutPipe:
;Sets up outgoing pipe
;Inputs:      A is max packet size / 8
       out (90h),a
       ld a,48h
       out (91h),a
       xor a
       out (92h),a
       ret

SetupInPipe:
;Sets up incoming pipe
;Inputs:      A is max packet size / 8
       out (93h),a
       ld a,90h
       out (94h),a
       xor a
       out (95h),a
       ret

SendInterruptData:
;Sends B bytes at HL to interrupt pipe C
;Returns carry if problems
       LOG IntData,b
       push hl
;       ld hl,USBflag
;       bit driverConfigured,(hl)
       pop hl
       scf
       ret z
       set indicOnly,(iy+indicFlags)
       ld a,c
;       ld (asm_ram),a
       ld c,0A0h
       add a,c
       ld c,a
       push bc
       ld de,0FFh
$$:    call DecrementCounter
       scf
       pop bc
       jr z,sendInterruptDataDone
       push bc
       in a,(8Eh)
       ld c,a
;       ld a,(asm_ram)
       out (8Eh),a
       in a,(91h)
       ld b,a
       ld a,c
       out (8Eh),a
       ld a,b
       and 1
       jr nz,$B
       pop bc
$$:    ld a,(hl)
       out (c),a
       inc hl
       djnz $B
       in a,(8Eh)
       ld c,a
;       ld a,(asm_ram)
       out (8Eh),a
       ld a,1
       out (91h),a
       ld a,c
       out (8Eh),a
       xor a
sendInterruptDataDone:
       res indicOnly,(iy+indicFlags)
       ret
DecrementCounter:
       dec de
       ld a,d
       or e
       ret
scfRet:
       scf
       ret

SendBulkData:
;Sends DE bytes at HL to bulk pipe 01
;Duplicates OS functionality
       ld c,01h
SendBulkDataC:
       set 0,(iy+41h)
       LOG BulkData,d
       LOG BulkData,e
       res 5,(iy+41h)
       ld a,0
       ld (9C7Dh),a
       ld (9C81h),de
       ld (9C7Eh),hl
       in a,(8Fh)
       bit 2,a
       jr z,$F
;       ret
$$:    ld a,c
       out (8Eh),a
       ld a,20h
       or c
       out (98h),a
       xor a
       in a,(98h)
       ld a,8
       out (90h),a
       xor a
       in a,(90h)
       ld a,0FFh
       out (87h),a
       xor a
       out (92h),a
       in a,(87h)
       ld a,0A1h
       out (8Bh),a
       in a,(8Bh)
;       in a,(86h)
       jr startSendData
sendDataLoop:
       xor a
       out (5Bh),a
       set 0,(iy+41h)
       ld b,40h
       ld a,c
       add a,0A0h
       ld c,a
$$:    call wasteTime
;       bit useExtraRAMPages,(iy+periph8xFlags)
       jr z,useRAM1
;       call getAfromHL_ExtraRAMPage
       jr continueSendLoop1
useRAM1:
       ld a,(hl)
continueSendLoop1:
       out (c),a
       inc hl
       dec de
       djnz $B
       ld a,c
       sub 0A0h
       ld c,a
       out (8Eh),a
       ld a,1
       out (91h),a
;       call DebugStart                          ;*** TESTING
waitLoop1:
       res 0,(iy+43h)
       bit 0,(iy+43h)
       jr z,$F
       in a,(91h)
       and 0D9h
       or 8
       out (91h),a
       scf
       ret
$$:    call isSendError
       jr nz,scfRet
       push bc
       in a,(82h)
$$:    srl a
       dec c
       jr nz,$B
       and 1
       pop bc
       jr z,waitLoop1
;       call DebugStop                           ;*** TESTING
       in a,(91h)
       bit 5,a
       jr nz,scfRet
       ld a,c
       out (8Eh),a
       ld a,8
       out (91h),a
startSendData:
       ld a,d
       or a
       jr nz,sendDataLoop
       ld a,e
       cp 40h
       jr nc,sendDataLoop
       push af
       xor a
       out (5Bh),a
       set 0,(iy+41h)
       pop af
       or a
       jr z,skipWrite
       ld b,a
       ld a,c
       add a,0A0h
       ld c,a
$$:    call wasteTime
;       bit useExtraRAMPages,(iy+periph8xFlags)
       jr z,useRAM2
;       call getAfromHL_ExtraRAMPage
       jr continueSendLoop2
useRAM2:
       ld a,(hl)
continueSendLoop2:
       out (c),a
       inc hl
       djnz $B
       ld a,c
       sub 0A0h
       ld c,a
skipWrite:
       ld a,c
       out (8Eh),a
       ld a,1
       out (91h),a
;       call DebugStart                          ;*** TESTING
waitLoop2:
       res 0,(iy+43h)
       bit 0,(iy+43h)
       jr z,$F
       in a,(91h)
       and 0D9h
       or 8
       out (91h),a
       scf
       ret
$$:    call isSendError
       jr nz,scfRet
       push bc
       in a,(82h)
$$:    srl a
       dec c
       jr nz,$B
       and 1
       pop bc
       jr z,waitLoop2
;       call DebugStop                           ;*** TESTING
       in a,(91h)
       bit 5,a
       jr nz,scfRet
       ld a,c
       out (8Eh),a
       ld a,8
       out (91h),a
       ld a,1
       out (5Bh),a
       res 0,(iy+41h)
;       ei
       ret
isSendError:
       in a,(86h)
       bit 5,a
       ret nz
       bit 7,a
       ret
wasteTime:
       nop
       inc hl
       dec hl
       push af
       push af
       pop af
       pop af
       inc hl
       dec hl
       nop
       call scfRet
       ccf
       call scfRet
       ccf
       ret

ReceiveLargeData:
;Receives BC bytes to HL on bulk pipe 02
;Duplicates OS functionality
       ld d,2
ReceiveLargeDataD:
       res 2,(iy+40h)
       res 5,(iy+43h)
       push bc
       push af
       ld (iMathPtr5),hl
       push de
receiveLargeLoop:
;       set 2,(iy+12h)
       res 3,(iy+8)
       push bc
       push hl
       ld hl,40h
       or a
       sbc hl,bc
       pop hl
       ld b,c
       jr nc,$F
       ld b,40h
$$:    pop hl
       pop af
       push af
       push hl
       ld d,a
       ld hl,(iMathPtr5)
       call ReceiveDataD
       ld (iMathPtr5),hl
       pop hl
;       call initCrystalTimer
       or a
       ld b,0
       sbc hl,bc
       jr z,$F
       ld b,h
       ld c,l
       jr receiveLargeLoop
$$:    pop de
       pop bc
       pop bc
       ret

ReceiveData:
;Receives B bytes to HL on bulk pipe 02, max size 40h
;Duplicates OS functionality
       ld d,2
ReceiveDataD:
       ld a,b
       or a
       ret z
       ld a,40h
       cp b
       ret c
       jr nz,$F
       nop
$$:    ld a,b
       ld (9C80h),a
;       ld a,(bytesRemaining)
       or a
       jr z,$F
       cp b
       jr nc,$F
       ld b,a
       ld (9C80h),a
$$:    in a,(8Fh)
       bit 2,a
       jr z,$F
       ret
$$:    ld a,d
       out (8Eh),a
       in a,(94h)
       bit 6,a
       jr z,$F
       and 0DFh
       out (94h),a
       pop af
       scf
       ret
$$:    ;ld a,(bytesRemaining)
       or a
       jr nz,$F
       in a,(96h)
$$:    push af
       ld c,0
receiveLoop:
       ld a,d
       add a,0A0h
       push bc
       ld c,a
       in a,(c)
       pop bc
;       bit 2,(iy+40h)
;       jr nz,receiveToZone1
;receiveToZone1:
;       bit useExtraRAMPages,(iy+periph8xFlags)
       jr z,$F
;       call putAtoHL_ExtraRAMPage
       jr continueReceiveLoop
$$:    ld (hl),a
continueReceiveLoop:
       inc hl
       inc c
       djnz receiveLoop
       ld a,d
       out (8Eh),a
       pop af
       sub c
;       ld (bytesRemaining),a
       ret nz
       xor a
;       ld (bytesRemaining),a
       in a,(94h)
       and 0FEh
       out (94h),a
       res 5,(iy+41h)
;       ld a,0A1h
       ld a,21h
       out (8Bh),a
       ld a,1
;       out (5Bh),a
       res 0,(iy+41h)
;       ei
       ret

initCrystalTimer:
;Sets up/Resets crystal timer that OS uses for USB stuff
;       di
       xor a
       out (33h),a
       ld a,43h
       out (33h),a
       ld a,3
       out (34h),a
       ld a,(90A8h)
       ld (90AAh),a
       ld a,(90A9h)
       ld (90ABh),a
       or a
       ld a,0FFh
       jr nz,$F
       ld a,(90A8h)
$$:    out (35h),a
       res 0,(iy+43h)
;       ei
       ret

initUSBStuff:
;Initializes memory and ports that OS uses for USB stuff
;Duplicates OS functionality
       set 1,(iy+43h)
       res 0,(iy+42h)
       ld hl,8449h
       ld (hl),74h
       res 0,(iy+42h)
       ld de,0FAh
       ld (90A0h),de
       ld (9094h),de
       ld a,14h
       ld (90A8h),a
       xor a
       ld (90A9h),a
       ld a,0
       ld (90A5h),a
       ret

sendUSBData_BCbytesFromHL:
;Sends BC bytes from HL out bulk pipe 01
;Duplicates OS functionality
       push hl
       push af
       push de
       push bc
       push bc
       pop de
       call SendBulkData
;       res useExtraRAMPages,(iy+periph8xFlags)
       jr c,sendFailed
       xor a
       jr zeroToDEret
sendFailed:
       ld de,0FFFFh
       or 1
       jr saveDEret
zeroToDEret:
       ld de,0
saveDEret:
       ld (90A6h),de
       pop bc
       pop de
       pop hl
       ld a,h
       pop hl
       ret

receiveAndWriteUSBData:
;Receives BC bytes to HL from bulk pipe 02
;Duplicates OS functionality
       set 2,(iy+40h)
       jr $F
receiveAndWriteUSBData_resFlag:
       res 2,(iy+40h)
$$:    res 5,(iy+43h)
receiveAndWriteUSBData_sub:
       push bc
       push af
       ld (iMathPtr5),hl
       bit 7,h
       jr nz,receiveUSBDataAndWriteLoop
       xor a
       ld (pagedCount),a
receiveUSBDataAndWriteLoop:
       bit 5,(iy+41h)
       jr nz,doTheRealReceiveAndWrite
       bit 0,(iy+43h)
       jr nz,returnProblemsBCis3
       bit 5,(iy+43h)
       jr z,doNotCheckForKeyLinkActivity
       res 2,(iy+12h)
       set 3,(iy+8)
;       B_CALL HandleLinkActivity
       ld a,(apdTimer)
       cp 1
       jr z,returnProblemsBCis3
doNotCheckForKeyLinkActivity:
       bit 5,(iy+41h)
       jr nz,doTheRealReceiveAndWrite
       push hl
       push bc
       ld hl,error_handler2
       call APP_PUSH_ERRORH
;       call checkForErrBreak
       call APP_POP_ERRORH
tryRecoveringFromError:
       pop bc
       pop hl
       jr receiveUSBDataAndWriteLoop
doTheRealReceiveAndWrite:
;       set 2,(iy+12h)
       res 3,(iy+8)
       bit 7,h
       jr nz,receiveToRAMInstead
receiveToRAMInstead:
       push bc
       push hl
       ld hl,40h
       or a
       sbc hl,bc
       pop hl
       ld b,c
       jr nc,notTooBig
       ld b,40h
notTooBig:
       call ReceiveData
       ex de,hl
       pop hl
       jr c,returnProblems_2
       call initCrystalTimer
       or a
       ld b,0
       sbc hl,bc
       jr z,routineDone
       ld b,h
       ld c,l
       ex de,hl
       jr receiveUSBDataAndWriteLoop
error_handler2:
       set 4,(iy+43h)
       bit 5,(iy+43h)
       jr z,tryRecoveringFromError
       call initCrystalTimer
       ld de,0CCCDh
       ld bc,0FFFEh
       pop hl
       pop hl
       jr problemsReturnNZ
returnProblems:
       pop bc
returnProblems_2:
       ld bc,0FFFFh
       jr problemsReturnNZ
returnProblemsBCis3:
       ld bc,3
problemsReturnNZ:
       or 1
       jr saveBCret
routineDone:
       ld bc,0
saveBCret:
       ld (90A6h),bc
       pop bc
       ld a,b
       pop bc
;       res useExtraRAMPages,(iy+periph8xFlags)
       ret

receiveAndWriteUSBData_fromInt:
       set 2,(iy+40h)
       push bc
       push af
       ld (iMathPtr5),hl
       xor a
       ld (9834h),a
       jr receive_data_ready
receiveAndWriteUSBData_noInt:
       set 2,(iy+40h)
$$:    push bc
       push af
       ld (iMathPtr5),hl
       xor a
       ld (9834h),a
receive_noint_loop:
       call doTimerStuff
       bit 0,(iy+43h)
       jr nz,P2scfRet
       bit 5,(iy+41h)
       jr nz,receive_data_ready
       in a,(84h)
       bit 2,a
       jr z,$F
       set 5,(iy+41h)
       xor a
;       ld (bytesRemaining),a
       jr receive_data_ready
$$:    in a,(86h)
       bit 5,a
       jr nz,P2scfRet
       jr receive_noint_loop
receive_data_ready:
       call initCrystalTimer
       push bc
       push hl
       ld hl,40h
       or a
       sbc hl,bc
       pop hl
       ld b,c
       jr nc,$F
       ld b,40h
$$:    call ReceiveData
       ex de,hl
       pop hl
       jr c,P2scfRet
       or a
       ld b,0
       sbc hl,bc
       jr z,$F
       ld b,h
       ld c,l
       ex de,hl
       jr receive_noint_loop
$$:    pop bc
       ld a,b
       pop bc
       ret
P2scfRet:
       pop af
       pop bc
       scf
       ret
doTimerStuff:
       in a,(4)
       and 40h
       ret z
       ld a,1
       out (34h),a
       ld a,(90ABh)
       or a
       jr nz,$F
       out (33h),a
       set 0,(iy+43h)
       ret
$$:    dec a
       ld (90ABh),a
       or a
       jr z,$F
       ret
$$:    xor a
       out (33h),a
       ld a,43h
       out (33h),a
       xor a
       out (34h),a
       ld a,(90AAh)
       out (35h),a
       ret

