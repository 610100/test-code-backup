/////////////////////////////////////////////////////////////////////////////
// Name:        samples/printing.h
// Purpose:     Printing demo for wxWidgets
// Author:      Julian Smart
// Modified by:
// Created:     1995
// RCS-ID:      $Id$
// Copyright:   (c) Julian Smart
// Licence:     wxWindows licence
/////////////////////////////////////////////////////////////////////////////

// Define a new application
class MyApp: public wxApp
{
public:
    MyApp() {}

    virtual bool OnInit();
    virtual int OnExit();

    void Draw(wxDC& dc);

    void IncrementAngle()
        { m_angle += 5; }
    void DecrementAngle()
        { m_angle -= 5; }

    wxFont& GetTestFont()
        { return m_testFont; }

private:
    int       m_angle;
    wxBitmap  m_bitmap;
    wxFont    m_testFont;
};

DECLARE_APP(MyApp)
class MyCanvas;

// Define a new canvas and frame
class MyFrame: public wxFrame
{
public:
    MyFrame(wxFrame *frame, const wxString& title, const wxPoint& pos, const wxSize& size);

    void OnAngleUp(wxCommandEvent& event);
    void OnAngleDown(wxCommandEvent& event);

    void OnPrint(wxCommandEvent& event);
    void OnPrintPreview(wxCommandEvent& event);
    void OnPageSetup(wxCommandEvent& event);
#if defined(__WXMSW__) && wxTEST_POSTSCRIPT_IN_MSW
    void OnPrintPS(wxCommandEvent& event);
    void OnPrintPreviewPS(wxCommandEvent& event);
    void OnPageSetupPS(wxCommandEvent& event);
#endif
#ifdef __WXMAC__
    void OnPageMargins(wxCommandEvent& event);
#endif

    void OnPreviewFrameModalityKind(wxCommandEvent& event);

    void OnExit(wxCommandEvent& event);
    void OnPrintAbout(wxCommandEvent& event);

private:
    MyCanvas* m_canvas;
    wxPreviewFrameModalityKind m_previewModality;

    DECLARE_EVENT_TABLE()
};

// Define a new white canvas
class MyCanvas: public wxScrolledWindow
{
public:
    MyCanvas(wxFrame *frame, const wxPoint& pos, const wxSize& size, long style = wxRETAINED);

    //void OnPaint(wxPaintEvent& evt);
    virtual void OnDraw(wxDC& dc);

private:
    DECLARE_EVENT_TABLE()
};

// Defines a new printout class to print our document
class MyPrintout: public wxPrintout
{
public:
    MyPrintout(MyFrame* frame, const wxString &title = wxT("My printout"))
        : wxPrintout(title) { m_frame=frame; }

    virtual bool OnPrintPage(int page);
    virtual bool HasPage(int page);
    virtual bool OnBeginDocument(int startPage, int endPage);
    virtual void GetPageInfo(int *minPage, int *maxPage, int *selPageFrom, int *selPageTo);

    void DrawPageOne();
    void DrawPageTwo();

    // Writes a header on a page. Margin units are in millimetres.
    bool WritePageHeader(wxPrintout *printout, wxDC *dc, const wxString& text, float mmToLogical);

private:
    MyFrame *m_frame;
};


// constants:
enum
{
    WXPRINT_PAGE_SETUP = 103,

    WXPRINT_PRINT_PS,
    WXPRINT_PAGE_SETUP_PS,
    WXPRINT_PREVIEW_PS,

    WXPRINT_ANGLEUP,
    WXPRINT_ANGLEDOWN,

#ifdef __WXMAC__
    WXPRINT_PAGE_MARGINS,
#endif

    WXPRINT_FRAME_MODAL_APP,
    WXPRINT_FRAME_MODAL_WIN,
    WXPRINT_FRAME_MODAL_NON
};
