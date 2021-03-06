VERSION 5.00
Begin VB.Form FormRelief 
   BackColor       =   &H80000005&
   BorderStyle     =   4  'Fixed ToolWindow
   Caption         =   " Relief"
   ClientHeight    =   6540
   ClientLeft      =   45
   ClientTop       =   285
   ClientWidth     =   12015
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   8.25
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   LinkTopic       =   "Form1"
   MaxButton       =   0   'False
   MinButton       =   0   'False
   ScaleHeight     =   436
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   801
   ShowInTaskbar   =   0   'False
   Begin PhotoDemon.pdCommandBar cmdBar 
      Align           =   2  'Align Bottom
      Height          =   750
      Left            =   0
      TabIndex        =   0
      Top             =   5790
      Width           =   12015
      _ExtentX        =   21193
      _ExtentY        =   1323
   End
   Begin PhotoDemon.pdFxPreviewCtl pdFxPreview 
      Height          =   5625
      Left            =   120
      TabIndex        =   1
      Top             =   120
      Width           =   5625
      _ExtentX        =   9922
      _ExtentY        =   9922
   End
   Begin PhotoDemon.pdSlider sltDistance 
      Height          =   705
      Left            =   6000
      TabIndex        =   2
      Top             =   2400
      Width           =   5895
      _ExtentX        =   10398
      _ExtentY        =   1270
      Caption         =   "thickness"
      Min             =   -10
      SigDigits       =   2
      Value           =   1
      DefaultValue    =   1
   End
   Begin PhotoDemon.pdSlider sltAngle 
      Height          =   705
      Left            =   6000
      TabIndex        =   3
      Top             =   1320
      Width           =   5895
      _ExtentX        =   10398
      _ExtentY        =   1270
      Caption         =   "angle"
      Min             =   -180
      Max             =   180
      SigDigits       =   1
   End
   Begin PhotoDemon.pdSlider sltDepth 
      Height          =   705
      Left            =   6000
      TabIndex        =   4
      Top             =   3480
      Width           =   5895
      _ExtentX        =   10398
      _ExtentY        =   1270
      Caption         =   "depth"
      Min             =   0.1
      SigDigits       =   2
      Value           =   1
      DefaultValue    =   1
   End
End
Attribute VB_Name = "FormRelief"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = False
'***************************************************************************
'Relief Artistic Effect Dialog
'Copyright 2003-2018 by Tanner Helland
'Created: sometime 2003
'Last updated: 26/July/17
'Last update: performance improvements, migrate to XML params
'
'This dialog applied a relief-style filter to an image.  Some kind of relief filter has existed in PD for a long time,
' but the 6.4 release saw some much-needed improvements in the form of selectable angle, depth, and thickness.
' Interpolation is used to process all relief calculations, so the result should be very good for any angle and/or
' depth combination, and edge handling is now handled much better than past versions of the tool.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'OK button
Private Sub cmdBar_OKClick()
    Process "Relief", , GetLocalParamString(), UNDO_Layer
End Sub

Private Sub cmdBar_RequestPreviewUpdate()
    UpdatePreview
End Sub

Private Sub cmdBar_ResetClick()
    sltDepth.Value = 1
    sltDistance.Value = 1
End Sub

Private Sub Form_Load()
    cmdBar.MarkPreviewStatus False
    ApplyThemeAndTranslations Me
    cmdBar.MarkPreviewStatus True
    UpdatePreview
End Sub

Private Sub Form_Unload(Cancel As Integer)
    ReleaseFormTheming Me
End Sub

'Apply a relief filter, which gives the image a pseudo-3D appearance
Public Sub ApplyReliefEffect(ByVal effectParams As String, Optional ByVal toPreview As Boolean = False, Optional ByRef dstPic As pdFxPreviewCtl)

    If (Not toPreview) Then Message "Carving image relief..."
    
    Dim cParams As pdParamXML
    Set cParams = New pdParamXML
    cParams.SetParamString effectParams
    
    Dim eDistance As Double, eAngle As Double, eDepth As Double
    
    With cParams
        eDistance = .GetDouble("distance", sltDistance.Value)
        eAngle = .GetDouble("angle", sltAngle.Value)
        eDepth = .GetDouble("depth", sltDepth.Value)
    End With
    
    'Don't allow distance to be 0
    If eDistance = 0# Then eDistance = 0.01
        
    'Create a local array and point it at the pixel data of the current image
    Dim dstImageData() As Byte
    Dim dstSA As SafeArray2D
    EffectPrep.PrepImageData dstSA, toPreview, dstPic
    CopyMemory ByVal VarPtrArray(dstImageData()), VarPtr(dstSA), 4
    
    'Create a second local array.  This will contain the a copy of the current image, and we will use it as our source reference
    ' (This is necessary to prevent already embossed pixels from screwing up our results for later pixels.)
    Dim srcImageData() As Byte
    Dim srcSA As SafeArray2D
    
    Dim srcDIB As pdDIB
    Set srcDIB = New pdDIB
    srcDIB.CreateFromExistingDIB workingDIB
    
    PrepSafeArray srcSA, srcDIB
    CopyMemory ByVal VarPtrArray(srcImageData()), VarPtr(srcSA), 4
        
    'Local loop variables can be more efficiently cached by VB's compiler, so we transfer all relevant loop data here
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = curDIBValues.Left
    initY = curDIBValues.Top
    finalX = curDIBValues.Right
    finalY = curDIBValues.Bottom
    
    'These values will help us access locations in the array more quickly.
    ' (qvDepth is required because the image array may be 24 or 32 bits per pixel, and we want to handle both cases.)
    Dim quickVal As Long, QuickValRight As Long, qvDepth As Long
    qvDepth = curDIBValues.BytesPerPixel
    
    'Create a filter support class, which will aid with edge handling and interpolation
    Dim fSupport As pdFilterSupport
    Set fSupport = New pdFilterSupport
    fSupport.SetDistortParameters qvDepth, EDGE_CLAMP, True, curDIBValues.maxX, curDIBValues.maxY
    
    'During previews, adjust the distance parameter to compensate for preview size
    If toPreview Then eDistance = eDistance * curDIBValues.previewModifier
    
    'To keep processing quick, only update the progress bar when absolutely necessary.  This function calculates that value
    ' based on the size of the area to be processed.
    Dim progBarCheck As Long
    progBarCheck = ProgressBars.FindBestProgBarValue()
    
    'Color variables
    Dim r As Long, g As Long, b As Long
    Dim tR As Long, tG As Long, tB As Long, tA As Long
    Dim reliefOffset As Double
    
    'Convert the rotation angle to radians
    eAngle = eAngle * (PI / 180)
    
    'Find the cos and sin of this angle and store the values
    Dim cosTheta As Double, sinTheta As Double
    cosTheta = Cos(eAngle)
    sinTheta = Sin(eAngle)
    
    'X value, remapped around a center point of (0, 0)
    Dim nX As Double
    
    'Source X and Y values, which are used to solve for the hue of a given point
    Dim srcX As Double, srcY As Double
    
    'Loop through each pixel in the image, converting values as we go
    For x = initX To finalX
        quickVal = x * qvDepth
        QuickValRight = (x + 1) * qvDepth
    For y = initY To finalY
    
        'Retrieve source RGB values
        b = srcImageData(quickVal, y)
        g = srcImageData(quickVal + 1, y)
        r = srcImageData(quickVal + 2, y)
        
        'Move x according to the user's distance parameter
        nX = x + eDistance
    
        'Calculate a rotated source x/y pixel
        srcX = cosTheta * (nX - x) + x
        srcY = sinTheta * (nX - x) + y
        
        'Use the filter support class to retrieve the pixel at that position, with interpolation and edge-wrapping
        ' automatically handled as necessary
        fSupport.GetColorsFromSource tR, tG, tB, tA, srcX, srcY, srcImageData
        
        'Calculate a single grayscale relief value
        reliefOffset = ((r - tR) + (g - tG) + (b - tB)) * 0.333333333333333
        reliefOffset = reliefOffset * eDepth
        
        'Apply the relief to each channel
        r = r + reliefOffset
        g = g + reliefOffset
        b = b + reliefOffset
                
        'Clamp RGB values
        If (r > 255) Then r = 255
        If (r < 0) Then r = 0
        If (g > 255) Then g = 255
        If (g < 0) Then g = 0
        If (b > 255) Then b = 255
        If (b < 0) Then b = 0
        
        dstImageData(quickVal, y) = b
        dstImageData(quickVal + 1, y) = g
        dstImageData(quickVal + 2, y) = r
        
    Next y
        If (Not toPreview) Then
            If (x And progBarCheck) = 0 Then
                If Interface.UserPressedESC() Then Exit For
                SetProgBarVal x
            End If
        End If
    Next x
    
    'Safely deallocate all image arrays
    CopyMemory ByVal VarPtrArray(srcImageData), 0&, 4
    CopyMemory ByVal VarPtrArray(dstImageData), 0&, 4
    
    'Pass control to finalizeImageData, which will handle the rest of the rendering
    EffectPrep.FinalizeImageData toPreview, dstPic
 
End Sub

'Render a new preview
Private Sub UpdatePreview()
    If cmdBar.PreviewsAllowed Then ApplyReliefEffect GetLocalParamString(), True, pdFxPreview
End Sub

'If the user changes the position and/or zoom of the preview viewport, the entire preview must be redrawn.
Private Sub pdFxPreview_ViewportChanged()
    UpdatePreview
End Sub

Private Sub sltAngle_Change()
    UpdatePreview
End Sub

Private Sub sltDepth_Change()
    UpdatePreview
End Sub

Private Sub sltDistance_Change()
    UpdatePreview
End Sub

Private Function GetLocalParamString() As String
    
    Dim cParams As pdParamXML
    Set cParams = New pdParamXML
    
    With cParams
        .AddParam "distance", sltDistance.Value
        .AddParam "angle", sltAngle.Value
        .AddParam "depth", sltDepth.Value
    End With
    
    GetLocalParamString = cParams.GetParamString()
    
End Function
