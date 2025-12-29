%%
%%  egd_display.erl --
%%
%%     A simple image viewer
%%
%%  Copyright (c) 2025 Dan Gudmundsson
%%

-module(egd_display).
-export([new/1, new/2]).

%% Internal exports
-export([init/1, terminate/2, code_change/3,
	 handle_sync_event/3, handle_event/2,
	 handle_cast/2, handle_info/2, handle_call/3]).

-behaviour(wx_object).

-include_lib("wx/include/wx.hrl").

%%%%%%%% API %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

new(Image) -> new(Image, []).

new({W,H,Bin}, Opts) ->
    wx:new(),
    Image = wxImage:new(W,H,Bin),
    new(Image, [destroy_after|Opts]);
new(Filename, Opts) when is_list(Filename) ->
    wx:new(),
    BlockWxMsgs = wxLogNull:new(),
    Img = wxImage:new(Filename),
    true = wxImage:ok(Img), %% Assert
    wxLogNull:destroy(BlockWxMsgs),
    new(Img, [{name,Filename}, destroy_after|Opts]);
new(Image, Opts) ->
    wx:new(),
    wxImage = wx:getObjectType(Image), %% Assert
    Name = proplists:get_value(name, Opts, ""),
    Type = proplists:get_value(type, Opts, ""),
    H0 = wxImage:getHeight(Image),
    W0 = wxImage:getWidth(Image),
    Title = lists:flatten(io_lib:format("Image: ~ts [~wx~w] ~s",[Name,W0,H0,Type])),
    Size = {size,{min(800,max(200,W0+100)), min(600,max(150,H0+100))}},

    case wx_object:start(egd_display, [Image, Title, [Size|Opts]], []) of
        {error, _} = Error ->
            Error;
        Window ->
            wxWindow:refresh(Window),
            Window
    end.


%%%%%%%% Progress bar internals %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {panel, ref, bitmap, bgb, scale=1.0, menu, origo={0,0}, prev}).

init([Image, Title, Opts]) ->
    Size = proplists:get_value(size, Opts),
    Frame = wxFrame:new(wx:null(), -1, Title, [{size, Size}]),
    Panel = wxPanel:new(Frame, [{style, ?wxFULL_REPAINT_ON_RESIZE}]),

    BM = wxBitmap:new(Image),
    proplists:get_value(destroy_after, Opts, false)
	andalso wxImage:destroy(Image),
    BGB = wxBrush:new({200,200,200}, [{style, ?wxCROSS_HATCH}]),

    wxPanel:connect(Panel, mousewheel),
    wxPanel:connect(Panel, right_up),
    wxPanel:connect(Panel, left_down),
    wxPanel:connect(Panel, motion),
    wxPanel:connect(Panel, erase_background), %% WIN32 only?
    wxPanel:connect(Panel, paint, [callback]),
    wxPanel:connect(Panel, enter_window, [{userData, {win, Panel}}]),
    wxFrame:show(Frame),
    %% wxFrame:createStatusBar(Frame),
    %% wxFrame:setStatusText(Frame, io_lib:format("Scale: ~w%", [100])),
    {Panel, #state{panel=Panel, bitmap=BM, bgb=BGB}}.

-define(wxGC, wxGraphicsContext).

handle_sync_event(#wx{obj=Panel, event=#wxPaint{}}, _,
		  #state{bitmap=Image, bgb=BGB, scale=Scale, origo={X,Y}}) ->
    DC = case os:type() of
	     {win32, _} -> %% Flicker on windows
	     	 wx:typeCast(wxBufferedPaintDC:new(Panel), wxPaintDC);
	     _ ->
		 wxPaintDC:new(Panel)
	 end,
    {W0,H0} = wxPanel:getClientSize(Panel),
    wxDC:setBackground(DC, ?wxWHITE_BRUSH),
    wxDC:clear(DC),

    H = wxBitmap:getHeight(Image),
    W = wxBitmap:getWidth(Image),

    GC = ?wxGC:create(DC),
    ?wxGC:setBrush(GC, BGB),
    ?wxGC:drawRectangle(GC, 0, 0, W0, H0),
    ?wxGC:translate(GC, X+(W0-Scale*W) / 2,Y+(H0-Scale*H) / 2),
    ?wxGC:scale(GC, Scale, Scale),
    ?wxGC:drawBitmap(GC, Image, 0,0, W,H),
    wxPaintDC:destroy(DC),
    %% wxFrame:setStatusText(Frame, io_lib:format("Scale: ~w%", [round(Scale*100.0)])),
    ok.

handle_event(#wx{event=#wxMouse{type=mousewheel, wheelRotation=Rot}},
	     #state{scale=Scale0, panel=Panel}=S) ->
    Scale = if Rot > 0.0 -> Scale0*1.2;
	      true -> Scale0/1.2
	   end,
    wxWindow:refresh(Panel),
    {noreply, S#state{scale=Scale}};

handle_event(#wx{event = #wxMouse{type = right_up}}, State=#state{panel=Panel}) ->
    Menu = wxMenu:new([]),
    wxMenu:append(Menu, 1012, "12%"),
    wxMenu:append(Menu, 1025, "25%"),
    wxMenu:append(Menu, 1050, "50%"),
    wxMenu:appendSeparator(Menu),
    wxMenu:append(Menu, 1100, "100%"),
    wxMenu:appendSeparator(Menu),
    wxMenu:append(Menu, 1200, "200%"),
    wxMenu:append(Menu, 1400, "400%"),
    wxMenu:append(Menu, 1800, "800%"),
    wxMenu:connect(Menu, command_menu_selected),
    wxWindow:popupMenu(Panel, Menu),
    {noreply, State#state{menu=Menu}};

handle_event(#wx{id=MenuId, event = #wxCommand{}},
	     State = #state{menu=Menu, panel=Panel}) ->
    wxMenu:destroy(Menu),
    wxWindow:refresh(Panel),
    {noreply, State#state{scale=(MenuId-1000)/100}};

handle_event(#wx{event=#wxMouse{type=motion, leftDown=true, x=X, y=Y}},
	     State=#state{prev={XP,YP}, origo={Xo,Yo}, panel=Panel}) ->
    wxWindow:refresh(Panel),
    {noreply, State#state{origo={Xo+X-XP,Yo+Y-YP}, prev={X,Y}}};

handle_event(#wx{event=#wxMouse{type=motion}}, State=#state{}) ->
    {noreply, State};

handle_event(#wx{event=#wxMouse{type=left_down,x=X,y=Y}}, State) ->
    {noreply, State#state{prev={X,Y}}};

handle_event(#wx{event=#wxMouse{type=enter_window}}, #state{panel=Panel}=State) ->
    wxWindow:setFocus(Panel),
    {noreply, State};

handle_event(#wx{event=#wxErase{}}, State) ->
    {noreply, State}.

handle_call(_Req, _From, State) ->
    {reply, keep, State}.

handle_cast({image_change, Image}, #state{panel=Panel,bitmap=Old}=State) ->
    wxBitmap:destroy(Old),
    BM = wxBitmap:new(Image),
    wxImage:destroy(Image),
    wxWindow:refresh(Panel),
    {noreply, State#state{bitmap=BM}};
handle_cast(_, State) -> {noreply, State}.

handle_info(_, State) -> {noreply, State}.

code_change(_, _, State) -> State.

terminate(_Reason, #state{bgb=BGB, bitmap=BM}) ->
    %%    io:format("terminate: ~p (~p)~n",[?MODULE, _Reason]),
    wxBitmap:destroy(BM),
    wxBrush:destroy(BGB),
    ok.
