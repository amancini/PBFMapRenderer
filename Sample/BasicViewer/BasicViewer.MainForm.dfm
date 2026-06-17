object MainForm: TMainForm
  Left = 0
  Top = 0
  Caption = 'PBFMapRenderer - Basic Tile Viewer'
  ClientHeight = 600
  ClientWidth = 560
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object img: TImage
    Left = 24
    Top = 86
    Width = 512
    Height = 512
  end
  object pnlTop: TPanel
    Left = 0
    Top = 0
    Width = 560
    Height = 80
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblZ: TLabel
      Left = 16
      Top = 48
      Width = 7
      Height = 15
      Caption = 'Z'
    end
    object lblX: TLabel
      Left = 96
      Top = 48
      Width = 7
      Height = 15
      Caption = 'X'
    end
    object lblY: TLabel
      Left = 200
      Top = 48
      Width = 7
      Height = 15
      Caption = 'Y'
    end
    object btnOpenTiles: TButton
      Left = 16
      Top = 12
      Width = 110
      Height = 25
      Caption = 'Open MBTiles...'
      TabOrder = 0
      OnClick = btnOpenTilesClick
    end
    object btnLoadStyle: TButton
      Left = 132
      Top = 12
      Width = 110
      Height = 25
      Caption = 'Load Style...'
      TabOrder = 1
      OnClick = btnLoadStyleClick
    end
    object edZ: TSpinEdit
      Left = 30
      Top = 44
      Width = 50
      Height = 24
      MaxValue = 22
      MinValue = 0
      TabOrder = 2
      Value = 14
    end
    object edX: TSpinEdit
      Left = 110
      Top = 44
      Width = 80
      Height = 24
      MaxValue = 0
      MinValue = 0
      TabOrder = 3
      Value = 0
    end
    object edY: TSpinEdit
      Left = 214
      Top = 44
      Width = 80
      Height = 24
      MaxValue = 0
      MinValue = 0
      TabOrder = 4
      Value = 0
    end
    object btnRender: TButton
      Left = 312
      Top = 43
      Width = 75
      Height = 25
      Caption = 'Render'
      TabOrder = 5
      OnClick = btnRenderClick
    end
    object btnRome: TButton
      Left = 400
      Top = 43
      Width = 110
      Height = 25
      Caption = 'Goto Rome z14'
      TabOrder = 6
      OnClick = btnRomeClick
    end
  end
  object sbStatus: TStatusBar
    Left = 0
    Top = 581
    Width = 560
    Height = 19
    Panels = <>
    SimplePanel = True
  end
  object dlgOpenTiles: TOpenDialog
    Filter = 'MBTiles|*.mbtiles|All files|*.*'
    Title = 'Open MBTiles'
    Left = 440
    Top = 8
  end
  object dlgOpenStyle: TOpenDialog
    Filter = 'Style JSON|*.json|All files|*.*'
    Title = 'Open style.json'
    Left = 496
    Top = 8
  end
  object FDGUIxWaitCursor1: TFDGUIxWaitCursor
    Provider = 'Forms'
    Left = 360
    Top = 288
  end
end
