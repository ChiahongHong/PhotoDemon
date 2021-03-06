VERSION 5.00
Begin VB.UserControl pdAccelerator 
   Appearance      =   0  'Flat
   BackColor       =   &H80000005&
   ClientHeight    =   3600
   ClientLeft      =   0
   ClientTop       =   0
   ClientWidth     =   4800
   ClipBehavior    =   0  'None
   DrawStyle       =   5  'Transparent
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   8.25
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   HasDC           =   0   'False
   InvisibleAtRuntime=   -1  'True
   ScaleHeight     =   240
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   320
   ToolboxBitmap   =   "pdAccelerator.ctx":0000
End
Attribute VB_Name = "pdAccelerator"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon Accelerator ("Hotkey") handler
'Copyright 2013-2018 by Tanner Helland and contributors
'Created: 06/November/15 (formally split off from a heavily modified vbaIHookControl by Steve McMahon
'Last updated: 08/December/17
'Last update by: jpbro (https://github.com/jpbro)
'Last update: queue rapidly fired hotkeys instead of just dropping them
'
'For many years, PD used vbAccelerator's "hook control" to handle program hotkeys:
' http://www.vbaccelerator.com/home/VB/Code/Libraries/Hooks/Accelerator_Control/article.asp
'
'Starting in August 2013 (https://github.com/tannerhelland/PhotoDemon/commit/373882e452201bb00584a52a791236e05bc97c1e),
' I rewrote much of the control to solve some glaring stability issues.  Over time, I rewrote it more and more
' (https://github.com/tannerhelland/PhotoDemon/commits/master/Controls/vbalHookControl.ctl), tacking on PD-specific
' features and attempting to fix problematic bugs, until ultimately the control became a horrible mishmash of
' spaghetti code: some old, some new, some completely unused, and some that was still problematic and unreliable.
'
'Because dynamic hooking has enormous potential for causing hard-to-replicate bugs, a ground-up rewrite seemed long
' overdue.  Hence this new control.
'
'Many thanks to Steve McMahon for his original implementation, which was my first introduction to hooking from VB6.
' It's still a fine reference for beginners, and you can find the original here (good as of November '15):
' http://www.vbaccelerator.com/home/VB/Code/Libraries/Hooks/Accelerator_Control/article.asp
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************


Option Explicit

'This control only raises a single "Accelerator" event, and it only does it when one (or more) keys in the combination are released
Public Event Accelerator(ByVal acceleratorIndex As Long)

' GetActiveWindow is used to determine if our main for is the active window in order to allow/prevent accelerator key accumulation
Private Declare Function GetActiveWindow Lib "user32.dll" () As Long

'Each hotkey stores several additional (and sometimes optional) parameters.  This spares us from writing specialized
' handling code for each individual keypress.
Private Type pdHotkey
    AccKeyCode As Long
    AccShiftState As ShiftConstants
    AccKeyName As String
    AccIsProcessorString As Boolean
    AccRequiresOpenImage As Boolean
    AccShowProcDialog As Boolean
    AccProcUndo As PD_UndoType
    AccMenuNameIfAny As String
End Type

'The list of hotkeys is stored in a basic array.  This makes it easy to set/retrieve values using built-in VB functions,
' and because the list of keys is short, performance isn't in issue.
Private m_Hotkeys() As pdHotkey
Private m_NumOfHotkeys As Long
Private Const INITIAL_HOTKEY_LIST_SIZE As Long = 16&

'In some places, virtual key-codes are used to retrieve key states
Private Const VK_SHIFT As Long = &H10
Private Const VK_CONTROL As Long = &H11
Private Const VK_ALT As Long = &H12    'Note that VK_ALT is referred to as VK_MENU in MSDN documentation!

'New solution!  Virtual-key tracking is a bad idea, because we want to know key state at the time the hotkey was pressed
' (not what it is right now).  Solving this is as easy as tracking key up/down state for Ctrl/Alt/Shift presses and
' storing the results locally.
Private m_CtrlDown As Boolean, m_AltDown As Boolean, m_ShiftDown As Boolean

'If the control's hook proc is active and primed, this will be set to TRUE.  (HookID is the actual Windows hook handle.)
Private m_HookingActive As Boolean, m_HookID As Long
Private Declare Function CallNextHookEx Lib "user32" (ByVal hHook As Long, ByVal nCode As Long, ByVal wParam As Long, ByVal lParam As Long) As Long
Private Declare Function UnhookWindowsHookEx Lib "user32" (ByVal hHook As Long) As Long

'When the control is actually inside the hook procedure, this will be set to TRUE.  The hook *cannot be removed
' until this returns to FALSE*.  To ensure correct unhooking behavior, we use a timer failsafe.
Private m_InHookNow As Boolean
Private m_InFireTimerNow As Boolean

'Keyboard accelerators are troublesome to handle because they interfere with PD's dynamic hooking solution for
' various canvas and control-related key events.  To work around this limitation, module-level variables are set
' by the accelerator hook control any time a potential accelerator is intercepted.  The hook then initiates an
' internal timer and immediately exits, which allows the keyboard hook proc to safely exit.  When the timer
' finishes enforcing a slight delay, we then perform the actual accelerator evaluation.
Private m_AcceleratorIndex As Long, m_TimerAtAcceleratorPress As Currency

'To reduce the potential for double-fired keys, we track the last-fired accelerator key and shift state, and compare
' it to the current one.  The current system keyboard delay must pass before we fire the same accelerator a second time.
Private m_LastAccKeyCode As Long, m_LastAccShiftState As ShiftConstants

'This control may be problematic on systems with system-wide custom key handlers (like some Intel systems, argh).
' As part of the debug process, we generate extra text on first activation - text that can be ignored on subsequent runs.
Private m_SubsequentInitialization As Boolean

'In-memory timers are used for firing accelerators and releasing hooks
Private WithEvents m_ReleaseTimer As pdTimer
Attribute m_ReleaseTimer.VB_VarHelpID = -1
Private WithEvents m_FireTimer As pdTimer
Attribute m_FireTimer.VB_VarHelpID = -1

'Thanks to a patch by jpbro (https://github.com/tannerhelland/PhotoDemon/pull/248), PD no longer drops accelerators
' that are triggered in quick succession.  Instead, it queues them and fires them in turn.
Private m_AcceleratorQueue As VBA.Collection        'Active queue of accelerators for which events are currently to be raised
Private m_AcceleratorAccumulator As VBA.Collection  'Queue of accelerators which are accumulating while the active queue is being processed

Public Function GetControlType() As PD_ControlType
    GetControlType = pdct_Accelerator
End Function

Public Function GetControlName() As String
    GetControlName = UserControl.Extender.Name
End Function

'The Enabled property is a bit unique; see http://msdn.microsoft.com/en-us/library/aa261357%28v=vs.60%29.aspx
Public Property Get Enabled() As Boolean
Attribute Enabled.VB_UserMemId = -514
    Enabled = UserControl.Enabled
End Property

Public Property Let Enabled(ByVal newValue As Boolean)
    UserControl.Enabled = newValue
    PropertyChanged "Enabled"
End Property

Private Sub m_FireTimer_Timer()
    
    Dim i As Long
    
    'If we're still inside the hookproc, wait another 16 ms before testing the keypress.
    If (Not m_InHookNow) Then
    
         If (Not CanIRaiseAnAcceleratorEvent(True)) Then
            
            'We are not currently allowed to raise any events, so short-circuit
            ' (If the program is shutting down, forcibly stop the timer so we don't raise hotkey events again)
            If g_ProgramShuttingDown Then m_FireTimer.StopTimer
            Exit Sub
            
         End If
        
         'Because the accelerator has now been processed, we can disable the timer; this will prevent it from firing again, but the
         ' current sub will still complete its actions.
         m_InFireTimerNow = True ' Notify other methods that we are busy in the timer
         m_FireTimer.StopTimer
         
         'Process accelerators in the active queue in FIFO order
         For i = 1 To m_AcceleratorQueue.Count
         
             m_AcceleratorIndex = m_AcceleratorQueue.Item(i)
         
             If (m_AcceleratorIndex <> -1) Then
                pdDebug.LogAction "raising accelerator-based event (#" & CStr(m_AcceleratorIndex) & ", " & HotKeyName(m_AcceleratorIndex) & ")"
                RaiseEvent Accelerator(m_AcceleratorIndex)
                m_AcceleratorIndex = -1
             End If
             
         Next i
         
         'Swap the active queue for the accumuator queue and empty the old accumulator queue object
         Set m_AcceleratorQueue = m_AcceleratorAccumulator
         Set m_AcceleratorAccumulator = New VBA.Collection
         
         'If we have accumulated accelerators that are now active, restart the timer
         If (m_AcceleratorQueue.Count > 0) Then m_FireTimer.StartTimer
         
         m_InFireTimerNow = False   'Clear the "busy in timer" flag
        
    End If
    
End Sub

Private Sub m_ReleaseTimer_Timer()
    If m_HookingActive Then
        SafelyReleaseHook
    Else
        m_ReleaseTimer.StopTimer
    End If
End Sub

'Hooks cannot be released while actually inside the hookproc.  Call this function to safely release a hook, even from within a hookproc.
Private Sub SafelyReleaseHook()
    
    If (Not pdMain.IsProgramRunning()) Then Exit Sub
    
    'If we're still inside the hook, activate the failsafe timer release mechanism
    If m_InHookNow Then
        If (Not m_ReleaseTimer Is Nothing) Then
            If (Not m_ReleaseTimer.IsActive) Then m_ReleaseTimer.StartTimer
        End If
        
    'If we're not inside the hook, this is a perfect time to release.
    Else
        
        If m_HookingActive Then
            m_HookingActive = False
            If (m_HookID <> 0) Then UnhookWindowsHookEx m_HookID
            m_HookID = 0
            VBHacks.NotifyAcceleratorHookNotNeeded ObjPtr(Me)
        End If
        
        'Also deactivate the failsafe timer
        If (Not m_ReleaseTimer Is Nothing) Then m_ReleaseTimer.StopTimer
        
    End If
    
End Sub

'Prior to shutdown, you can call this function to forcibly release as many accelerator resources as we can.  In PD,
' we use this to free our menu references.
Public Sub ReleaseResources()
    If Not (m_ReleaseTimer Is Nothing) Then Set m_ReleaseTimer = Nothing
    If Not (m_FireTimer Is Nothing) Then Set m_FireTimer = Nothing
End Sub

Private Sub UserControl_Initialize()
    Set m_AcceleratorQueue = New VBA.Collection
    Set m_AcceleratorAccumulator = New VBA.Collection
    
    m_HookingActive = False
    m_AcceleratorIndex = -1
    
    m_NumOfHotkeys = 0
    ReDim m_Hotkeys(0 To INITIAL_HOTKEY_LIST_SIZE - 1) As pdHotkey
        
    'You may want to consider straight-up disabling hotkeys inside the IDE
    If pdMain.IsProgramRunning() Then
        
        'UI-related timers run at 60 fps
        Set m_ReleaseTimer = New pdTimer
        m_ReleaseTimer.Interval = 17
        
        Set m_FireTimer = New pdTimer
        m_FireTimer.Interval = 17
        
        'Hooks are not installed at initialization.  The program must explicitly request initialization.
        
    End If
    
End Sub

Private Sub UserControl_Terminate()
    
    'Generally, we prefer the caller to disable us manually, but as a last resort, check for termination at shutdown time.
    If (m_HookID <> 0) Then DeactivateHook True
    
    ReleaseResources
    
End Sub

'Hook activation/deactivation must be controlled manually by the caller
Public Function ActivateHook() As Boolean
    
    If pdMain.IsProgramRunning() Then
        
        'If we're already hooked, don't attempt to hook again
        If (Not m_HookingActive) Then
            
            m_HookID = VBHacks.NotifyAcceleratorHookNeeded(Me)
            m_HookingActive = (m_HookID <> 0)
            
            If (Not m_SubsequentInitialization) Then
                If (Not m_HookingActive) Then pdDebug.LogAction "WARNING!  pdAccelerator.ActivateHook failed.   Hotkeys disabled for this session."
            End If
            m_SubsequentInitialization = True
            
            ActivateHook = m_HookingActive
            
        End If
        
    End If
    
End Function

Public Sub DeactivateHook(Optional ByVal forciblyReleaseInstantly As Boolean = True)
    
    If m_HookingActive Then
        
        If forciblyReleaseInstantly Then
            m_HookingActive = False
            VBHacks.NotifyAcceleratorHookNotNeeded ObjPtr(Me)
            If (m_HookID <> 0) Then UnhookWindowsHookEx m_HookID
            m_HookID = 0
        Else
            SafelyReleaseHook
        End If
        
    End If
    
End Sub

'Add a new accelerator key combination to the collection.  A ton of PD-specific functionality is included in this function, so let me break it down.
' - "isProcessorString": if TRUE, hotKeyName is assumed to a be a string meant for PD's central processor.  It will be directly passed
'    to the processor there when that hotkey is used.
' - "correspondingMenu": a reference to the menu associated with this hotkey.  The reference is used to dynamically draw matching shortcut text
'    onto the menu.  It is not otherwise used.
' - "requiresOpenImage": specifies that this action *must be disallowed* unless one (or more) image(s) are loaded and active.
' - "showProcForm": controls the "showDialog" parameter of processor string directives.
' - "procUndo": controls the "createUndo" parameter of processor string directives.  Remember that UNDO_NOTHING means "do not create Undo data."
Public Function AddAccelerator(ByVal vKeyCode As KeyCodeConstants, Optional ByVal Shift As ShiftConstants = 0&, Optional ByVal HotKeyName As String = vbNullString, Optional ByRef correspondingMenu As String = vbNullString, Optional ByVal IsProcessorString As Boolean = False, Optional ByVal requiresOpenImage As Boolean = True, Optional ByVal showProcDialog As Boolean = True, Optional ByVal procUndo As PD_UndoType = UNDO_Nothing) As Long
    
    'Make sure this key combination doesn't already exist in the collection
    Dim failsafeCheck As Long
    failsafeCheck = GetAcceleratorIndex(vKeyCode, Shift)
    
    If (failsafeCheck >= 0) Then
        AddAccelerator = failsafeCheck
        Exit Function
    End If
    
    'We now know that this key combination is unique.
    
    'Make sure the list is large enough to hold this new entry.
    If (m_NumOfHotkeys > UBound(m_Hotkeys)) Then ReDim Preserve m_Hotkeys(0 To UBound(m_Hotkeys) * 2 + 1) As pdHotkey
    
    'Add the new entry
    With m_Hotkeys(m_NumOfHotkeys)
        .AccKeyCode = vKeyCode
        .AccShiftState = Shift
        .AccKeyName = HotKeyName
        .AccMenuNameIfAny = correspondingMenu
        .AccIsProcessorString = IsProcessorString
        .AccRequiresOpenImage = requiresOpenImage
        .AccShowProcDialog = showProcDialog
        .AccProcUndo = procUndo
    End With
    
    'Return this index, and increment the active hotkey count
    AddAccelerator = m_NumOfHotkeys
    m_NumOfHotkeys = m_NumOfHotkeys + 1
    
End Function

'If an accelerator exists in our current collection, this will return a value >= 0 corresponding to its position in the master array.
Private Function GetAcceleratorIndex(ByVal vKeyCode As KeyCodeConstants, ByVal Shift As ShiftConstants) As Long
    
    GetAcceleratorIndex = -1
    
    If (m_NumOfHotkeys > 0) Then
        
        Dim i As Long
        For i = 0 To m_NumOfHotkeys - 1
            If (m_Hotkeys(i).AccKeyCode = vKeyCode) And (m_Hotkeys(i).AccShiftState = Shift) Then
                GetAcceleratorIndex = i
                Exit For
            End If
        Next i
        
    End If

End Function

'Outside functions can retrieve certain accelerator properties.  Note that - by design - these properties should only be retrieved from inside
' an Accelerator event.
Public Function Count() As Long
    Count = m_NumOfHotkeys
End Function

Public Function IsProcessorString(ByVal hkIndex As Long) As Boolean
    If (hkIndex >= 0) And (hkIndex < m_NumOfHotkeys) Then
        IsProcessorString = m_Hotkeys(hkIndex).AccIsProcessorString
    End If
End Function

Public Function IsImageRequired(ByVal hkIndex As Long) As Boolean
    If (hkIndex >= 0) And (hkIndex < m_NumOfHotkeys) Then
        IsImageRequired = m_Hotkeys(hkIndex).AccRequiresOpenImage
    End If
End Function

Public Function IsDialogDisplayed(ByVal hkIndex As Long) As Boolean
    If (hkIndex >= 0) And (hkIndex < m_NumOfHotkeys) Then
        IsDialogDisplayed = m_Hotkeys(hkIndex).AccShowProcDialog
    End If
End Function

Public Function HasMenu(ByVal hkIndex As Long) As Boolean
    If (hkIndex >= 0) And (hkIndex < m_NumOfHotkeys) Then
        HasMenu = (Len(m_Hotkeys(hkIndex).AccMenuNameIfAny) <> 0)
    End If
End Function

Public Function HotKeyName(ByVal hkIndex As Long) As String
    If (hkIndex >= 0) And (hkIndex < m_NumOfHotkeys) Then
        HotKeyName = m_Hotkeys(hkIndex).AccKeyName
    End If
End Function

Public Function GetMenuName(ByVal hkIndex As Long) As String
    If (hkIndex >= 0) And (hkIndex < m_NumOfHotkeys) Then
        GetMenuName = m_Hotkeys(hkIndex).AccMenuNameIfAny
    End If
End Function

Public Function GetKeyCode(ByVal hkIndex As Long) As KeyCodeConstants
    If (hkIndex >= 0) And (hkIndex < m_NumOfHotkeys) Then
        GetKeyCode = m_Hotkeys(hkIndex).AccKeyCode
    End If
End Function

Public Function GetShift(ByVal hkIndex As Long) As ShiftConstants
    If (hkIndex >= 0) And (hkIndex < m_NumOfHotkeys) Then
        GetShift = m_Hotkeys(hkIndex).AccShiftState
    End If
End Function

Public Function ProcUndoValue(ByVal hkIndex As Long) As PD_UndoType
    ProcUndoValue = m_Hotkeys(hkIndex).AccProcUndo
End Function

'VB exposes a UserControl.EventsFrozen property to check for IDE breaks, but in my testing it isn't reliable.
Private Function AreEventsFrozen() As Boolean
    
    On Error GoTo EventStateCheckError
    
    If UserControl.Enabled Then
        If pdMain.IsProgramRunning() Then
            AreEventsFrozen = UserControl.EventsFrozen
        Else
            AreEventsFrozen = True
        End If
    Else
        AreEventsFrozen = True
    End If
    
    Exit Function

'If an error occurs, assume events are frozen
EventStateCheckError:
    AreEventsFrozen = True
    
End Function

'Returns: TRUE if hotkeys are allowed to accumulate.
Private Function CanIAccumulateAnAccelerator() As Boolean
    CanIAccumulateAnAccelerator = (Not Interface.IsModalDialogActive())
End Function

'Want to globally disable accelerators under certain circumstances?  Add code here to do it.
Private Function CanIRaiseAnAcceleratorEvent(Optional ByVal ignoreActiveTimer As Boolean = False) As Boolean
   
    'By default, assume we can raise accelerator events
    CanIRaiseAnAcceleratorEvent = True
    
    'I'm not entirely sure how VB's message pumps work when WM_TIMER events hit disabled controls, so just to be safe,
    ' let's be paranoid and ensure this control hasn't been externally deactivated.
    If (Me.Enabled And (m_NumOfHotkeys > 0)) Then
        
        'Don't process accelerators when the main form is disabled (e.g. if a modal form is present, or if a previous
        ' action is in the middle of execution)
        If (Not FormMain.Enabled) Then CanIRaiseAnAcceleratorEvent = False
        
        'If the accelerator timer is already waiting to process an existing accelerator, exit.  (We'll get a chance to
        ' try again on the next timer event.)
        If (m_FireTimer Is Nothing) Then
            CanIRaiseAnAcceleratorEvent = False
        Else
            
            'If the timer is active, let it finish its current task before we attempt to raise another accelerator
            If (Not ignoreActiveTimer) And m_FireTimer.IsActive Then CanIRaiseAnAcceleratorEvent = False
            If m_InFireTimerNow Then CanIRaiseAnAcceleratorEvent = False
            
        End If
        
        'If PD is shutting down, we obviously want to ignore accelerators entirely
        If g_ProgramShuttingDown Then CanIRaiseAnAcceleratorEvent = False
    
    'If this control is disabled or no hotkeys have been loaded (a potential possibility in future builds, when the
    ' user will have control over custom hotkeys), save some CPU cycles and prevent further processing.
    Else
        CanIRaiseAnAcceleratorEvent = False
    End If
    
End Function

Private Function HandleActualKeypress(ByVal nCode As Long, ByVal wParam As Long, ByVal lParam As Long, ByVal p_AccumulateOnly As Boolean) As Boolean
    
    'Translate modifier states (shift, control, alt/menu) to their masked VB equivalent
    Dim retShiftConstants As ShiftConstants
    If m_CtrlDown Then retShiftConstants = retShiftConstants Or vbCtrlMask
    If m_AltDown Then retShiftConstants = retShiftConstants Or vbAltMask
    If m_ShiftDown Then retShiftConstants = retShiftConstants Or vbShiftMask
    
    'Search our accelerator database for a match to the current keycode
    If (m_NumOfHotkeys > 0) Then
        
        Dim i As Long
        For i = 0 To m_NumOfHotkeys - 1
            
            'First, see if the keycode matches.
            If (m_Hotkeys(i).AccKeyCode = wParam) Then
                
                'Next, see if the Ctrl+Alt+Shift state matches
                If (m_Hotkeys(i).AccShiftState = retShiftConstants) Then
                
                    'We have a match!
                    
                    'We have one last check to perform before firing this accelerator.  Users with accessibility constraints
                    ' (including elderly users) may press-and-hold accelerators long enough to trigger repeat occurrences.
                    ' Accelerators should require full "release key and press again" behavior to avoid double-firing
                    ' their associated events.
                    If (m_Hotkeys(i).AccKeyCode = m_LastAccKeyCode) And (m_Hotkeys(i).AccShiftState = m_LastAccShiftState) Then
                        If (VBHacks.GetTimerDifferenceNow(m_TimerAtAcceleratorPress) < Interface.GetKeyboardDelay()) Then
                           Exit For
                        End If
                    End If
                    
                    m_AcceleratorIndex = i
                    VBHacks.GetHighResTime m_TimerAtAcceleratorPress
                    
                    If p_AccumulateOnly Then
                        'Add to accelerator accumulator, it will be processed later.
                        m_AcceleratorAccumulator.Add m_AcceleratorIndex
                        
                    Else
                        'Add to the live accelerator processing queue
                        m_AcceleratorQueue.Add m_AcceleratorIndex
                     
                       If (Not m_FireTimer Is Nothing) Then m_FireTimer.StartTimer
                    End If
                    
                    'Also, make sure to eat this keystroke
                    HandleActualKeypress = True
                    
                    m_LastAccKeyCode = m_Hotkeys(i).AccKeyCode
                    m_LastAccShiftState = m_Hotkeys(i).AccShiftState
                    
                    Exit For
                
                End If
                
            End If
        
        Next i
    
    End If  'Hotkey collection exists
    
End Function

Private Function UpdateCtrlAltShiftState(ByVal wParam As Long, ByVal lParam As Long) As Boolean
    
    UpdateCtrlAltShiftState = False
    
    If (wParam = VK_CONTROL) Then
        m_CtrlDown = (lParam >= 0)
        UpdateCtrlAltShiftState = True
    ElseIf (wParam = VK_ALT) Then
        m_AltDown = (lParam >= 0)
        UpdateCtrlAltShiftState = True
    ElseIf (wParam = VK_SHIFT) Then
        m_ShiftDown = (lParam >= 0)
        UpdateCtrlAltShiftState = True
    End If
    
End Function

Friend Function KeyboardHookProcAccelerator(ByVal nCode As Long, ByVal wParam As Long, ByVal lParam As Long) As Long
    
    m_InHookNow = True
    On Error GoTo HookProcError
    
    Dim msgEaten As Boolean: msgEaten = False
    
    'Try to see if we're in an IDE break mode.  This isn't 100% reliable, but it's better than not checking at all.
    If (Not AreEventsFrozen) Then
        
        'MSDN states that negative codes must be passed to the next hook, without processing
        ' (see http://msdn.microsoft.com/en-us/library/ms644984.aspx).  Similarly, hooks passed with the code "3"
        ' mean that this is not an actual key event, but one triggered by a PeekMessage() call with PM_NOREMOVE specified.
        ' We can ignore such peeks and only deal with actual key events.
        If (nCode = 0) Then
            
            'Key hook callbacks can be raised under a variety of conditions.  To ensure we only track actual "key down"
            ' or "key up" events, let's compare transition and previous states.  Because hotkeys are (by design) not
            ' triggered by hold-to-repeat behavior, we only want to deal with key events that are full transitions from
            ' "Unpressed" to "Pressed" or vice-versa.  (The byte masks here all come from MSDN - check the link above
            ' for details!)
            If ((lParam >= 0) And ((lParam And &H40000000) = 0)) Or ((lParam < 0) And ((lParam And &H40000000) <> 0)) Then
                
                'We now want to check two things simultaneously.  First, we want to update Ctrl/Alt/Shift key state tracking.
                ' (This is handled by a separate function.)  If something other than Ctrl/Alt/Shift was pressed, *and* this is
                ' a keydown event, let's process the key for hotkey matches.
                
                '(How do we detect keydown vs keyup events?  The first bit (e.g. "bit 31" per MSDN) of lParam defines key state:
                ' 0 means the key is being pressed, 1 means the key is being released.  Note the similarity to the transition
                ' check, above.)
                If (lParam >= 0) And (Not UpdateCtrlAltShiftState(wParam, lParam)) Then
                
                    'Before proceeding with further checks, see if PD is even allowed to process accelerators in its
                    ' current state (e.g. if a modal dialog is active, we don't want to raise events)
                    If CanIAccumulateAnAccelerator Then
                    
                        'All checks have passed.  We'll handle the actual keycode evaluation matching in another function.
                        msgEaten = HandleActualKeypress(nCode, wParam, lParam, m_InFireTimerNow Or (Not CanIRaiseAnAcceleratorEvent))
                        
                    End If
                    
                End If  'Key is not in a transitionary state
                
            End If  'Key other than Ctrl/Alt/Shift was pressed
            
        End If  'nCode is not negative
        
    End If  'Events are not frozen
    
    'If we didn't handle this keypress, allow subsequent hooks to have their way with it
    If (Not msgEaten) Then
        KeyboardHookProcAccelerator = CallNextHookEx(0, nCode, wParam, lParam)
    Else
        KeyboardHookProcAccelerator = 1
    End If
    
    m_InHookNow = False
    Exit Function
    
'On errors, we simply want to bail, as there's little we can safely do to address an error from inside the hooking procedure
HookProcError:
    
    KeyboardHookProcAccelerator = CallNextHookEx(0, nCode, wParam, lParam)
    m_InHookNow = False
    
End Function

