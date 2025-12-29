%%
%%  egd_ttf.erl --
%%
%%     Functions for reading TrueType fonts (.tt)
%%
%% %CopyrightBegin%
%%
%% Copyright Dan Gudmundsson 2025. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%

%% For TrueType format, see http://www.microsoft.com/typography/otspec/
%% Based on https://github.com/nothings/stb/blob/master/stb_truetype.h

-module(egd_ttf).
-export([init/0, list_fonts/0, load/1,
         get_text_extent/2, text_horizontal_ls/3,
         scale_for_mapping_em_to_pixels/2,
         get_font_v_metrics/1,
         init_font/2, sysfontdirs/0, process_ttfs/1, find_font_info/1
        ]).

-import(lists, [reverse/1,sort/2,keysearch/3,duplicate/2,nthtail/2,
		mapfoldl/3,foldl/3,sublist/3,map/2,last/1,seq/2,seq/3,
		flatten/1,sum/1,append/1]).

-record(ttf_info,
	{num_glyphs,     %% Number of Glyphs

	 %% Offsets to table locations
	 loca, glyf, head, hhea, vhea, hmtx, gpos, kern, name, os2,
         cff,           %% undefined or initatied CFF info
	 index_map,     %% A Cmap mapping for out  chosen character encoding
	 index_to_loc_format, %% Format needed to map from glyph index to glyph
         file,          %% Filename
         collection=0,  %% Collection number
	 data           %% The binary file
	}).

-record(vertex, {pos, c, c1, type}).

-define(DEF_SIZE, 14).

-type ttf() :: #ttf_info{}.
%% -type scale() :: Uniform::float() | {ScaleX::float(),ScaleY::float()}.
%% -type shift() :: Uniform::float() | {ShiftX::float(),ShiftY::float()}.
%% -type size() :: {Width::integer(), Height::integer()}.
-type vertex() :: #vertex{}.
-type platform() :: unicode | mac | microsoft | integer().
-type encoding() :: unicode | roman | integer().
-type language() :: english | integer().  %% 0 if platform is unicode

-define (fsITALIC, 2#00000001).
-define (fsBOLD,   2#00100000).

%% PLATFORM ID
-define(PLATFORM_ID_UNICODE,  0).
-define(PLATFORM_ID_MAC,      1).
-define(PLATFORM_ID_ISO,      2).
-define(PLATFORM_ID_MICROSOFT,3).

%%  encodingID for PLATFORM_ID_UNICODE
-define(UNICODE_EID_UNICODE_1_0    ,0).
-define(UNICODE_EID_UNICODE_1_1    ,1).
-define(UNICODE_EID_ISO_10646      ,2).
-define(UNICODE_EID_UNICODE_2_0_BMP,3).
-define(UNICODE_EID_UNICODE_2_0_FULL,4).

%% encodingID for PLATFORM_ID_MICROSOFT
-define(MS_EID_SYMBOL        ,0).
-define(MS_EID_UNICODE_BMP   ,1).
-define(MS_EID_SHIFTJIS      ,2).
-define(MS_EID_UNICODE_FULL  ,10).

%% encodingID for PLATFORM_ID_MAC; same as Script Manager codes
-define(MAC_EID_ROMAN        ,0).
-define(MAC_EID_JAPANESE     ,1).
-define(MAC_EID_CHINESE_TRAD ,2).
-define(MAC_EID_KOREAN       ,3).
-define(MAC_EID_ARABIC       ,4).
-define(MAC_EID_HEBREW       ,5).
-define(MAC_EID_GREEK        ,6).
-define(MAC_EID_RUSSIAN      ,7).

-define(S16, 16/signed).
-define(U16, 16/unsigned).
-define(S32, 32/signed).
-define(U32, 32/unsigned).
-define(SKIP, _/binary).

%%-define(ttf_debug, true).
-ifdef(ttf_debug).
-define(DBG(F,A), io:format("~w:~w: "++ F, [?MODULE,?LINE] ++ A)).
-define(assert(Test), true = (Test)).
-else.
-define(DBG(F,A), ok).
-define(assert(Test), ok).
-endif.


init() ->
    FontDirs = sysfontdirs(),
    _DefFont  = default_font(),
    _GbtFonts = process_ttfs(FontDirs),
    ok.

list_fonts() ->
    All = ets:foldl(fun({Desc, _File}, Acc) -> [Desc | Acc] end, [], ?MODULE),
    [#{face => Family, family => PrefFamily, style => Style, weight => Weight}
     || {Family, PrefFamily, Style, Weight} <- lists:sort(All)].

load(#{} = FontInfo) ->
    case find_font_file(?MODULE, FontInfo) of
        {_, {_, {File, Idx} = Ref}} ->
            case ets:lookup(?MODULE, {cache, Ref}) of
                [] ->
                    try
                        TTF = init_font(File, Idx),
                        true = ets:insert(?MODULE, {{cache, Ref}, TTF}),
                        FontInfo#{ref => Ref}
                    catch throw:Error ->
                            error(Error)
                    end;
                [{_, _}] ->
                    FontInfo#{ref => Ref}
            end
    end.

get_text_extent(#{ref := Ref} = FontInfo, Text) ->
    Size = maps:get(size, FontInfo, ?DEF_SIZE),
    [{_, TTF}] = ets:lookup(?MODULE, {cache, Ref}),
    Scale = scale_for_mapping_em_to_pixels(TTF, Size),
    {Ascent, _Descent, _LineGap} = get_font_v_metrics(TTF),
    Baseline = Ascent,
    Extent = fun(CodePoint, {W, YMin, YMax}) ->
                     Glyph = find_glyph_index(TTF, CodePoint),
                     {Advance, _} = get_glyph_h_metrics(TTF, Glyph),
                     {_X0,Y0,_X1,Y1} = get_glyph_box(TTF, Glyph),
                     %% ?DBG("~c: Base: ~w Y0 ~w Y1 ~w~n", [CodePoint, Baseline, Y0, Y1]),
                     {W + Advance, min(YMin,Y0), max(YMax, Y1)}
             end,
    {W, YMin, _YMax} = lists:foldl(Extent, {0, 1_000_000, -1}, Text),
    %% We need to use baseline here, otherwise we might miss some lines at the bottom.
    {ceil(W*Scale), ceil((Baseline-YMin)*Scale)}.


text_horizontal_ls({X0,Y0}, #{ref := Ref} = Font, Chars) ->
    Size = maps:get(size, Font, ?DEF_SIZE),
    [{_,TTF}] =  ets:lookup(?MODULE, {cache, Ref}),
    Scale = scale_for_mapping_em_to_pixels(TTF, Size),
    SubDiv = max(Size div 10+1, 2),
    {Ascent, _Descent, _LineGap} = get_font_v_metrics(TTF),
    Baseline = ceil(Ascent*Scale),
    try
        Ls = text_horizontal_ls(Chars, TTF, SubDiv, Y0+Baseline, Scale, float(X0), []),
        lists:flatten(Ls)
    catch Error ->
            error(Error)
    end.

text_horizontal_ls([CodePoint|Rest], TTF, SubDiv, Y0, Scale, X0, Acc) ->
    Glyph = find_glyph_index(TTF, CodePoint),
    XShift = X0 - floor(X0),
    GlyphVs = get_glyph_shape(TTF, Glyph),
    VsCont = verts_to_point_lists(GlyphVs, Scale, SubDiv),
    Es = get_sorted_edges(VsCont, Scale, XShift, 0.0),
    {Ix0, Iy0, Ix1, Iy1} = get_glyph_bitmap_box(TTF, Glyph, Scale, XShift, 0.0),
    %% ?DBG("Base ~w:~w Ix0 ~w Ix1 ~w Iy0 ~w Iy1 ~w~n",[X0, Y0, Ix0, Ix1, Iy0, Iy1]),
    RLines = rasterize_sorted(Es, floor(X0+Ix0), Y0, Ix1-Ix0, Iy1-Iy0, Ix0, Iy0),
    {Advance, _LSB} = get_glyph_h_metrics(TTF, Glyph),
    KernAdvance =
        case Rest of
            [Next|_] ->
                get_glyph_kern_advance(TTF, Glyph, find_glyph_index(TTF, Next));
            _ ->
                0
        end,
    %% ?DBG("Char: ~c Glyph: ~w Advance: ~p*~p=~p LSB: ~w Kern: ~w~n",
    %%      [CodePoint, Glyph, Advance, Scale, Advance*Scale, _LSB, KernAdvance]),
    XNext = X0+(KernAdvance+Advance)*Scale,
    text_horizontal_ls(Rest, TTF, SubDiv, Y0, Scale, XNext, RLines ++ Acc);
text_horizontal_ls([], _TTF, _SubDiv, _Y0, _Scale, _X0, Acc) ->
    Acc.

get_sorted_edges(VsCont, Scale, ShiftX, ShiftY) ->
    Make = fun(Vs) -> make_edges(Vs, Scale, -Scale, ShiftX, ShiftY, []) end,
    Edges0 = lists:map(Make, VsCont),
    Edges = [Edge || [_|_] = Edge <- Edges0],  %% Filter out empty lists
    sort_edges(lists:flatten(Edges)).

sort_edges(Es) ->
    %% Sort on X if equal Y pixel?
    lists:sort(fun({{AX,AY},_,_}, {{BX,BY},_,_}) ->
                       if AY =:= BY -> AX < BX;
                          true -> AY < BY
                       end
               end, Es).

verts_to_point_lists(Vs, Scale, SubDiv) ->
    L = 0.1,
    F = {L*L/Scale, SubDiv},
    lists:reverse(verts_to_points(Vs, {0.0,0.0}, F, [], [])).

verts_to_points([#vertex{type=move,pos=Point}|Vs], _, F, Cont, All) ->
    verts_to_points(Vs, Point, F, [Point], add_contour(Cont, All));
verts_to_points([#vertex{type=line,pos=Point}|Vs], _, F, Cont, All) ->
    verts_to_points(Vs, Point, F, [Point|Cont], All);
verts_to_points([#vertex{type=curve,pos=VP={PX,PY},c={CX,CY}}|Vs],
                {X,Y}, {Limit,Level}=F, Cont0, All) ->
    Cont = tesselate_curve(X,Y, CX,CY, PX,PY, Limit, Level, Cont0),
    verts_to_points(Vs, VP, F, Cont, All);
verts_to_points([#vertex{type=cubic,pos=VP={PX,PY},c={CX,CY}, c1={CX1,CY1}}|Vs],
                {X,Y}, {Limit,Level}=F, Cont0, All) ->
    Cont = tesselate_cubic(X,Y, CX,CY, CX1,CY1, PX,PY, Limit, Level, Cont0),
    verts_to_points(Vs, VP, F, Cont, All);
verts_to_points([], _, _, Cont, All) ->
    add_contour(Cont, All).

add_contour([], All) -> All;
add_contour(Cont, All) ->
    [lists:reverse(Cont)|All].

tesselate_curve(X0,Y0, X1,Y1, X2,Y2, Limit, Level, Cont0) when Level >= 0 ->
    Mx = (X0 + 2*X1 + X2)/4.0,
    My = (Y0 + 2*Y1 + Y2)/4.0,
    %% Versus Directly Drawn Line
    Dx = (X0+X2)/2.0 - Mx,
    Dy = (Y0+Y2)/2.0 - My,
    if (Dx*Dx+Dy*Dy) > Limit ->
	    Cont1 = tesselate_curve(X0,Y0, (X0+X1)/2.0,(Y0+Y1)/2.0, Mx,My, Limit, Level-1, Cont0),
	    tesselate_curve(Mx,My, (X1+X2)/2.0,(Y1+Y2)/2.0, X2,Y2, Limit, Level-1, Cont1);
       true ->
	    [{X2,Y2}|Cont0]
    end;
tesselate_curve(_X0,_Y0, _X1,_Y1, X2,Y2, _F, _Level, Cont) ->
    [{X2,Y2}|Cont].

tesselate_cubic(X0,Y0, X1,Y1, X2,Y2, X3,Y3, Limit, Level, Cont0) when Level >= 0 ->
    Dx0 = X1-X0, Dy0 = Y1-Y0,
    Dx1 = X2-X1, Dy1 = Y2-Y1,
    Dx2 = X3-X2, Dy2 = Y3-Y2,
    Dx  = X3-X0, Dy  = Y3-Y0,

    LL = math:sqrt(Dx0*Dx0+Dy0*Dy0)+math:sqrt(Dx1*Dx1+Dy1*Dy1)+math:sqrt(Dx2*Dx2+Dy2*Dy2),
    SL = math:sqrt(Dx*Dx+Dy*Dy),

    if (LL*LL-SL*SL) > Limit ->
            X01 = (X0+X1)/2,  Y01 = (Y0+Y1)/2,
            X12 = (X1+X2)/2,  Y12 = (Y1+Y2)/2,
            X23 = (X2+X3)/2,  Y23 = (Y2+Y3)/2,

            Xa  = (X01+X12)/2, Ya = (Y01+Y12)/2,
            Xb  = (X12+X23)/2, Yb = (Y12+Y23)/2,

            Mx  = (Xa+Xb)/2,   My = (Ya+Yb)/2,

	    Cont1 = tesselate_cubic(X0,Y0, X01,Y01, Xa,Ya, Mx,My, Limit, Level-1, Cont0),
	    tesselate_cubic(Mx,My, Xb,Yb, X23,Y23, X3,Y3, Limit, Level-1, Cont1);
       true ->
	    [{X3,Y3}|Cont0]
    end;
tesselate_cubic(_X0,_Y0, _X1,_Y1, _X2,_Y2, X3,Y3, _F, _Level, Cont) ->
    [{X3,Y3}|Cont].

bb_box(ListOfLists) ->
    SetMM = fun({X,Y}, {MinX,MinY,MaxX,MaxY}) ->
                    {min(X,MinX), min(Y,MinY),
                     max(X,MaxX), max(X,MaxY)}
            end,
    VMM = fun(#vertex{pos = Pos, c1=undefined}, MinMax) ->
                  SetMM(Pos, MinMax);
             (#vertex{pos = Pos, c=C, c1=C1}, MinMax) ->
                  MM1 = SetMM(Pos, MinMax),
                  MM2 = SetMM(C, MM1),
                  SetMM(C1, MM2)
          end,
    L = 1 bsl 16,
    lists:foldl(fun(List, Acc) -> lists:foldl(VMM, Acc, List) end,
                {L,L, -L,-L}, ListOfLists).

make_edges([{JX,JY}|Rest=[{KX,KY}|_]], ScaleX, ScaleY, ShiftX, ShiftY, Eds) ->
    V0 = {JX * ScaleX+ShiftX, JY * ScaleY+ShiftY},
    V1 = {KX * ScaleX+ShiftX, KY * ScaleY+ShiftY},
    Edge = case JY > KY of
               true  -> {V0, V1, true};
               false -> {V1, V0, false}
           end,
    case Edge of
        {V,V} ->  %% Remove zero size edges
            make_edges(Rest, ScaleX, ScaleY, ShiftX, ShiftY, Eds);
        _ when JY == KY ->  %% Remove horizontal edges
            make_edges(Rest, ScaleX, ScaleY, ShiftX, ShiftY, Eds);
        _ ->
            make_edges(Rest, ScaleX, ScaleY, ShiftX, ShiftY, [Edge|Eds])
    end;
make_edges(_, _, _, _, _, Eds) ->
    lists:reverse(Eds).

-record(ae,
        {fx,
         fdx, fdy,
         dir,
         sy,   %% start Y
         ey}). %% end Y

rasterize_sorted(Es, SX, SY, Width, Height, XOff, YOff) ->
    rasterize_sorted(Es, SX, SY, Width, Height, XOff, YOff, [], []).

rasterize_sorted([], _SX, _SY, _W, _H, _X, _Y, [], Rasterized) ->
    Rasterized;
rasterize_sorted(Es0, SX, SY, Width, H, X, Y, Active0, Rasterized0) ->
    ScanTop = Y,
    ScanBott = Y+1,
    Active1 = update_active(Active0, ScanTop),
    {Es, Active2} = add_active(Es0, ScanBott, ScanTop, X, Active1),
    Zeros = array:new([{default, 0.0}, {size, Width}]),
    Zeros1 = array:new([{default, 0.0}, {size, Width+1}]),
    {SL, Fill} = fill_active_edges(Active2, ScanTop, ScanBott, Zeros, Zeros1),
    Active = advance_all_edges(Active2),
    {Pos, Bytes} = calc_row_bytes(array:to_list(SL), array:to_list(Fill), 0.0, []),
    case Bytes of
        [] ->
            rasterize_sorted(Es, SX, SY, Width, H, X, Y+1, Active, Rasterized0);
        [First|Rest] ->
            LineSpan = make_line_span(Rest, First, SX+Pos, SX+Pos, SY+Y, []),
            %% ?DBG("XPos ~w+~w=~w  ~w~n",[SX,Pos,SX+Pos, LineSpan]),
            rasterize_sorted(Es, SX, SY, Width, H, X, Y+1, Active, [LineSpan|Rasterized0])
    end.

calc_row_bytes([S|Scan], [F|Fill], Sum0, Acc) ->
    Sum = Sum0+F,
    K0 = S+Sum,
    K = abs(K0)*255.0+0.5,
    M = case floor(K) of
            M0 when M0 > 255 -> 255;
            M0 -> M0
        end,
    calc_row_bytes(Scan, Fill, Sum, [M|Acc]);
calc_row_bytes([], [_], _, RevBytes0) ->
    {_, RevBytes} = strip(RevBytes0, 0),
    strip(reverse(RevBytes), 0).

strip([0|Rest], N) ->
    strip(Rest, N+1);
strip(Bytes, N) ->
    {N, Bytes}.

make_line_span([A|Rest], A, Start, End, Y, Acc) ->
    make_line_span(Rest, A, Start, End+1, Y, Acc);
make_line_span([A|Rest], Curr, Start, End, Y, Acc0) ->
    Acc = case Curr of
              0 -> Acc0;
              _ -> [{Y, Start, End, Curr}|Acc0]
          end,
    make_line_span(Rest, A, End+1, End+1, Y, Acc);
make_line_span([], Curr, Start, End, Y, Acc0) ->
    [{Y, Start, End, Curr}|Acc0].

update_active([#ae{ey = EY}|Rest], ScanTop)
  when EY =< ScanTop ->
    update_active(Rest, ScanTop);
update_active([AE|Rest], ScanTop) ->
    [AE|update_active(Rest, ScanTop)];
update_active([], _) ->
    [].

add_active([{{_X0,Y0}, {_X1,Y1}, _}|Rest], ScanBott, ScanTop, X, Active)
  when Y0 == Y1 ->
    add_active(Rest, ScanBott, ScanTop, X, Active);
add_active([{{_X0,Y0}, _, _}=E|Rest], ScanBott, ScanTop, X, Active)
  when Y0 =< ScanBott->
    New = new_active(E, X, ScanTop),
    %% Magic patching is done here ?
    add_active(Rest, ScanBott, ScanTop, X, [New|Active]);
add_active(Rest, _ScanBott, _ScanTop, _X, Active) ->
    {Rest, Active}.

new_active({{X0,Y0}, {X1,Y1}, Inv}, XOff, ScanTop) ->
    DxDy = (X1-X0) / (Y1-Y0),
    Fdx = DxDy,
    Fdy = if DxDy /= 0.0 -> 1.0/DxDy; true -> 0.0 end,
    Fx = X0 + DxDy * (ScanTop - Y0) - XOff,
    Dir = if Inv -> 1.0; true -> -1.0 end,
    #ae{fdx = Fdx, fdy = Fdy, fx = Fx, dir = Dir, sy = Y0, ey=Y1}.

advance_all_edges([#ae{fx = Fx, fdx=Fdx}=E|Rest]) ->
    [E#ae{fx = Fx+Fdx} | advance_all_edges(Rest)];
advance_all_edges([]) ->
    [].

fill_active_edges([#ae{fx = Fx, fdx=+0.0}=E|Rest], Top, Bottom, Scan0, Fill0) ->
    {Scan, Fill} =
        if Fx >= 0.0 ->
                {handle_clipped_edge(Scan0, 0, floor(Fx), E, Fx, Top, Fx, Bottom),
                 handle_clipped_edge(Fill0, 0, floor(Fx+1), E, Fx, Top, Fx, Bottom)};
           true ->
                {Scan0,
                 handle_clipped_edge(Fill0, 0, Fx, E, Fx, Top, Fx, Bottom)}
        end,
    fill_active_edges(Rest, Top, Bottom, Scan, Fill);
fill_active_edges([#ae{fx = X0, fdx=Dx, fdy=Dy, sy=Sy, ey=Ey, dir=Dir}|Rest],
                  YTop, YBottom, Scan0, Fill0) ->
    ?assert(Sy =< YBottom andalso Ey >= YTop),

    %% compute endpoints of line segment clipped to this scanline (if the
    %% line segment starts on this scanline. x0 is the intersection of the
    %% line with y_top, but that may be off the line segment.
    Xb = X0 + Dx,
    {XTop, Sy0} =
        if Sy > YTop ->
                {X0 + Dx*(Sy-YTop), Sy};
           true ->
                {X0, YTop}
        end,
    {XBottom, Sy1} =
        if Ey < YBottom ->
                {X0 + Dx*(Ey-YTop), Ey};
           true ->
                {Xb, YBottom}
        end,
    ?assert(XTop >= 0 andalso XBottom >= 0),
    {Scan, Fill} =
        if floor(XTop) == floor(XBottom) ->
                %% simple case, only spans one pixel
                H =  (Sy1 - Sy0) * Dir,
                X = floor(XTop),
                A = trapezoid_area(H, XTop, X+1.0, XBottom, X+1.0),
                {array_add(X, A, Scan0),
                 array_add(X+1, H, Fill0)};
           XTop > XBottom ->
                Sy0T = YBottom - (Sy0 - YTop),
                Sy1T = YBottom - (Sy1 - YTop),
                ?assert(-Dx >= 0),
                ?assert(-Dy >= 0),
                fill_active_edges_inside(Sy1T, Sy0T, XBottom, XTop, YTop, YBottom,
                                         Dir, -Dy, Xb, Scan0, Fill0);
           true ->
                ?assert(Dx >= 0),
                ?assert(Dy >= 0),
                fill_active_edges_inside(Sy0, Sy1,   XTop, XBottom, YTop, YBottom,
                                         Dir, Dy,  X0, Scan0, Fill0)
        end,
    fill_active_edges(Rest, YTop, YBottom, Scan, Fill);
fill_active_edges([], _YTop, _YBottom, Scan, Fill) ->
    {Scan, Fill}.

fill_active_edges_inside(Sy0, Sy1, XTop, XBottom, YTop, YBottom, Dir, Dy0, X0, Scan0, Fill0) ->
    %% covers 2+ pixels

    X1 = floor(XTop),
    X2 = floor(XBottom),
    %% compute intersection with y axis at x1+1
    Y_crossing =
        case YTop + Dy0 * (X1+1 - X0) of
            %% @TODO: maybe test against sy1 rather than y_bottom?
            Ycross when Ycross > YBottom -> YBottom;
            Ycross -> Ycross
        end,
    %% compute intersection with y axis at x2
    {Y_final, Dy} =
        case YTop + Dy0 * (X2 - X0) of
            Yfinal when Yfinal > YBottom ->
                %% check if final y_crossing is blown up; no test case for this
                {YBottom,
                 %% if denom=0, y_final = y_crossing, so y_final <= y_bottom
                 (YBottom - Y_crossing ) / (X2 - (X1+1))};
            Yfinal ->
                {Yfinal, Dy0}
        end,
    %%           x1    x_top                            x2    x_bottom
    %%     y_top  +------|-----+------------+------------+--------|---+------------+
    %%            |            |            |            |            |            |
    %%            |            |            |            |            |            |
    %%       sy0  |      Txxxxx|............|............|............|............|
    %% y_crossing |            *xxxxx.......|............|............|............|
    %%            |            |     xxxxx..|............|............|............|
    %%            |            |     /-   xx*xxxx........|............|............|
    %%            |            | dy <       |    xxxxxx..|............|............|
    %%   y_final  |            |     \-     |          xx*xxx.........|............|
    %%       sy1  |            |            |            |   xxxxxB...|............|
    %%            |            |            |            |            |            |
    %%            |            |            |            |            |            |
    %%  y_bottom  +------------+------------+------------+------------+------------+
    %%
    %% goal is to measure the area covered by '.' in each pixel

    %% if x2 is right at the right edge of x1, y_crossing can blow up, github #1057
    Sign = Dir,

    %% area of the rectangle covered from sy0..y_crossing
    Area = Sign * (Y_crossing-Sy0),

    %% area of the triangle (x_top,sy0), (x1+1,sy0), (x1+1,y_crossing)
    Scan1 = array_add(X1, triangle_area(Area, X1+1 - XTop), Scan0),

    %% in second pixel, area covered by line segment found in first pixel
    %% is always a rectangle 1 wide * the height of that line segment; this
    %% is exactly what the variable 'area' stores. it also gets a contribution
    %% from the line segment within it. the THIRD pixel will get the first
    %% pixel's rectangle contribution, the second pixel's rectangle contribution,
    %% and its own contribution. the 'own contribution' is the same in every pixel except
    %% the leftmost and rightmost, a trapezoid that slides down in each pixel.
    %% the second pixel's contribution to the third pixel will be the
    %% rectangle 1 wide times the height change in the second pixel, which is dy.

    Step = Sign * Dy,  %% dy is dy/dx, change in y for every 1 change in x,
    %% which multiplied by 1-pixel-width is how much pixel area changes for each step in x
    %% so the area advances by 'step' every time

    {Scan2, Area1} = add_area(X1+1, X2, Area, Step, Scan1),

    ?assert(abs(Area1) =< 1.01), %% accumulated error from area += step unless we round step down
    ?assert(Sy1 > Y_final-0.01),

    %% area covered in the last pixel is the rectangle from all the pixels to the left,
    %% plus the trapezoid filled by the line segment in this pixel all the way to the right edge
    TA = trapezoid_area(Sy1-Y_final, float(X2), X2+1.0, XBottom, X2+1.0),
    Scan = array_add(X2, Area1 + Sign * TA, Scan2),

    %% the rest of the line is filled based on the total height of the line segment in this pixel
    Fill = array_add(X2+1, Sign * (Sy1-Sy0), Fill0),
    {Scan, Fill}.

add_area(X, X2, Area, Step, Scan0)
  when X < X2 ->
    Scan = array_add(X, Area + Step/2, Scan0), %% area of trapezoid is 1*step/2
    add_area(X+1, X2, Area + Step, Step, Scan);
add_area(_X, _X2, Area, _Step, Scan) ->
    {Scan, Area}.

trapezoid_area(H, Tx0, Tx1, Bx0, Bx1) ->
    TW = Tx1-Tx0,
    BW = Bx1-Bx0,
    ?assert(TW >= 0),
    ?assert(BW >= 0),
    (TW+BW) / 2.0*H.

triangle_area(H,W) ->
    H*W/2.0.

array_add(Idx, Add, Array) ->
    try
        Val = array:get(Idx, Array),
        array:set(Idx, Val+Add, Array)
    catch _:_ ->
            io:format("~w: Idx: ~w Array ~w~n", [?LINE, Idx, array:size(Array)]),
            error({array_badarg, Idx})
    end.

handle_clipped_edge(Scan, _Off, _X, _E, _X0, Y0,  _X1, Y1)
  when Y0 == Y1 -> Scan;
handle_clipped_edge(Scan, _Off, _X, #ae{ey=Ey}, _X0, Y0,  _X1, _Y1)
  when Y0 > Ey -> Scan;
handle_clipped_edge(Scan, _Off, _X, #ae{sy=Sy}, _X0, _Y0,  _X1, Y1)
  when Y1 < Sy -> Scan;
handle_clipped_edge(Scan, Off, X, #ae{ey=Ey, sy=Sy, dir = Dir}, X00, Y00,  X10, Y10) ->
    {X0,Y0} =
        if Y00 < Sy ->
                {X00 + (X10-X00)*(Sy - Y00)/(Y10-Y00), Sy};
           true ->
                {X00, Y00}
        end,
    {X1,Y1} =
        if Y10 > Ey ->
                {X10 + (X10-X0)*(Ey - Y10)/(Y10-Y0), Ey};
           true ->
                {X10, Y10}
        end,
    %% Asserts
    if (X0 == X) -> ?assert(X1 =< X+1);
       (X0 == X+1) -> ?assert(X1 >= X);
       (X0 =< X) -> ?assert(X1 =< X);
       (X0 >= X+1) -> ?assert(X1 >= X+1);
       true -> ?assert(X1 >= X andalso X1 =< X+1)
    end,

    Idx = X+Off,
    if X0 =< X, X1 =< X ->
            Value = Dir * (Y1-Y0),
            array_add(Idx, Value, Scan);
       X0 >= X+1, X1 >= X+1 ->
            Scan;
       true ->
            ?assert(X0 >= X andalso X0 =< X+1 andalso X1 >= X andalso X1 =< X+1),
            Value = Dir * (Y1-Y0) * (1.0-((X0-X)+(X1-X))/2.0),
            array_add(Idx, Value, Scan)
    end.

%%%

%%%%%%%%%%%%%%%%%%%%% TTF PARSER %%%%%%%%%%%%%%%%%%%%


%% Heavily inspired from Sean Barret's code @ nothings.org (see stb_truetype.h)
%%
%% @doc
%%      Codepoint
%%         Characters are defined by unicode codepoints, e.g. 65 is
%%         uppercase A, 231 is lowercase c with a cedilla, 0x7e30 is
%%         the hiragana for "ma".
%%
%%      Glyph
%%         A visual character shape (every codepoint is rendered as
%%         some glyph)
%%
%%      Glyph index
%%         A font-specific integer ID representing a glyph
%%
%%      Baseline
%%         Glyph shapes are defined relative to a baseline, which is the
%%         bottom of uppercase characters. Characters extend both above
%%         and below the baseline.
%%
%%      Current Point
%%         As you draw text to the screen, you keep track of a "current point"
%%         which is the origin of each character. The current point's vertical
%%         position is the baseline. Even "baked fonts" use this model.
%%
%%      Vertical Font Metrics
%%         The vertical qualities of the font, used to vertically position
%%         and space the characters. See docs for get_font_v_metrics.
%%
%%      Font Size in Pixels or Points
%%         The preferred interface for specifying font sizes in truetype
%%         is to specify how tall the font's vertical extent should be in pixels.
%%         If that sounds good enough, skip the next paragraph.
%%
%%         Most font APIs instead use "points", which are a common typographic
%%         measurement for describing font size, defined as 72 points per inch.
%%         truetype provides a point API for compatibility. However, true
%%         "per inch" conventions don't make much sense on computer displays
%%         since they different monitors have different number of pixels per
%%         inch. For example, Windows traditionally uses a convention that
%%         there are 96 pixels per inch, thus making 'inch' measurements have
%%         nothing to do with inches, and thus effectively defining a point to
%%         be 1.333 pixels. Additionally, the TrueType font data provides
%%         an explicit scale factor to scale a given font's glyphs to points,
%%         but the author has observed that this scale factor is often wrong
%%         for non-commercial fonts, thus making fonts scaled in points
%%         according to the TrueType spec incoherently sized in practice.
%%

%% Each .ttf/.ttc file may have more than one font. Each font has a
%% sequential index number starting from 0. A regular .ttf file will
%% only define one font and it always be at index 0.

platform(0) -> unicode;
platform(1) -> mac;
platform(2) -> iso;
platform(3) -> microsoft;
platform(Id) -> Id.

encoding(0, unicode) -> {unicode, {1,0}};
encoding(1, unicode) -> {unicode, {1,1}};
encoding(2, unicode) -> iso_10646;
encoding(3, unicode) -> {unicode, bmp, {2,0}};
encoding(4, unicode) -> {unicode, full,{2,0}};
encoding(5, unicode) -> {unicode_nyi, format_14};

encoding(0, microsoft)  -> symbol;
encoding(1, microsoft)  -> {unicode, bmp};
encoding(2, microsoft)  -> shiftjis;
encoding(10, microsoft) -> {unicode, bmp};

encoding(0, mac) ->  roman        ;
encoding(1, mac) ->  japanese     ;
encoding(2, mac) ->  chinese_trad ;
encoding(3, mac) ->  korean       ;
encoding(4, mac) ->  arabic       ;
encoding(5, mac) ->  hebrew       ;
encoding(6, mac) ->  greek        ;
encoding(7, mac) ->  russian      ;

encoding(Id, _) -> Id.

language(0 , mac) -> english ;
language(12, mac) -> arabic  ;
language(4 , mac) -> dutch   ;
language(1 , mac) -> french  ;
language(2 , mac) -> german  ;
language(10, mac) -> hebrew  ;
language(3 , mac) -> italian ;
language(11, mac) -> japanese;
language(23, mac) -> korean  ;
language(32, mac) -> russian ;
language(6 , mac) -> spanish ;
language(5 , mac) -> swedish ;
language(33, mac) -> chinese_simplified ;
language(19, mac) -> chinese ;

language(16#0409, microsoft) -> english ;
language(16#0804, microsoft) -> chinese ;
language(16#0413, microsoft) -> dutch   ;
language(16#040c, microsoft) -> french  ;
language(16#0407, microsoft) -> german  ;
language(16#040d, microsoft) -> hebrew  ;
language(16#0410, microsoft) -> italian ;
language(16#0411, microsoft) -> japanese;
language(16#0412, microsoft) -> korean  ;
language(16#0419, microsoft) -> russian ;
%%language(16#0409, microsoft) -> spanish ;
language(16#041d, microsoft) -> swedish ;
language(Id, _) -> Id.

info(0) -> copyright;
info(1) -> family;
info(2) -> subfamily;
info(3) -> unique_subfamily;
info(4) -> fullname;
info(5) -> version;
info(6) -> postscript_name;
info(7) -> trademark_notice;
info(8) -> manufacturer_name;
info(9) -> designer;
info(10) -> description;
info(11) -> url_vendor;
info(12) -> url_designer;
info(13) -> license_descr;
info(14) -> url_license;
%info(15) -> reserved;
info(16) -> preferred_family;
info(17) -> preferred_subfamily;
%%info(18) -> compatible_full; %% Mac only
info(19) -> sample_text;
info(Id) -> Id.


process_ttfs(Dirs) ->
    case ets:info(?MODULE) of
        undefined ->
            Tab = ets:new(?MODULE, [named_table, public]),
            Add = fun(FileName, _Acc) ->
                          Store = fun(FontInfo0, Idx) ->
                                          {Key,_} = KV =
                                              case FontInfo0 of
                                                  {error, Reason, FI} ->
                                                      {FI, {{error, Reason, FileName}, Idx}};
                                                  FI ->
                                                      {FI, {FileName,Idx}}
                                              end,
                                          case ets:lookup(Tab, Key) of
                                              [] -> ok;
                                              [_Old] ->
                                                  %% ?DBG("Overwrite Font Info:~nOLD: ~p~nNEW: ~p~n",
                                                  %%      [_Old,{FontInfo,{FileName,Idx}}]),
                                                  ok
                                          end,
                                          true = ets:insert(Tab, KV),
                                          Idx+1
                                  end,
                          try find_font_info(FileName) of
                              List ->
                                  lists:foldl(Store, 0, List),
                                  ok
                          catch _:_What:_St ->
                                  ?DBG("Fail: ~p : ~P~n ~P~n",[FileName, _What, 20, _St, 20]),
                                  ok
                          end
                  end,
            Filter = ".ttf|.TTF|.ttc|.TTC|.otf|.OTF",
            lists:foldl(fun(Dir, Tree) ->
                                filelib:fold_files(Dir, Filter, true, Add, Tree)
                        end, ok, Dirs),
            Tab;
        [_|_] ->
            ?MODULE
    end.

%% ttf fonts start with an "offset subtable":
%%  uint32 - tag to mark as TTF (one of the 0,1,0,0; "true"; or "OTTO")
%%  uint16 - number of directory tables
%%  uint16 - search range: (maximum power of 2 <= numTables)*16
%%  uint16 - entry selector: log2(maximum power of 2 <= numTables)
%%  uint16 - range shift: numTables*16-searchRange

is_font(<<1,0,0,0,?SKIP>>) -> true;  %% Truetype 1
is_font(<<"typ1",?SKIP>>)  -> true;  %% Truetype with type 1 font, not supported
is_font(<<"OTTO",?SKIP>>)  -> true;  %% OpenType with CFF
is_font(<<0,1,0,0,?SKIP>>) -> true;  %% OpenType with 1.0
is_font(_) -> false.

%% is_ttfc(<<"ttcf", ?SKIP>>) -> true;
%% is_ttfc(_) -> false.


-spec init_font(FileName, Index) -> ttf() when
      FileName :: list(),
      Index :: integer().
init_font(Filename, Index) ->
    case file:read_file(Filename) of
	{ok, Bin} -> init_font_1(Filename, Bin, Index);
	{error,Error} -> throw({error, {Error, "Couldn't open file" ++ Filename}})
    end.

init_font_1(Filename, Bin0, Index) ->
    Bin  = get_font_from_offset(Bin0, Index),
    is_font(Bin) orelse throw({error, bad_ttf_file}),
    Tabs = find_tables(Bin),
    Name = case maps:get(<<"name">>, Tabs, undefined) of
               undefined -> throw({error, bad_ttf_file});
               NameData -> NameData
           end,
    Os2  = maps:get(<<"OS/2">>, Tabs, undefined),
    try
        CMap = maps:get(<<"cmap">>, Tabs),
        %% Either loca and glyf
        Loca = maps:get(<<"loca">>, Tabs, undefined),
        Glyf = maps:get(<<"glyf">>, Tabs, undefined),
        %% or CFF is needed
        Cff  = maps:get(<<"CFF ">>, Tabs, undefined),
        Head = maps:get(<<"head">>, Tabs),
        Hhea = maps:get(<<"hhea">>, Tabs),
        Vhea = maps:get(<<"vhea">>, Tabs, undefined),
        Hmtx = maps:get(<<"hmtx">>, Tabs),
        Kern = maps:get(<<"kern">>, Tabs, undefined),
        Gpos = maps:get(<<"GPOS">>, Tabs, undefined),
        NumGlyphs = num_glyphs(maps:get(<<"maxp">>, Tabs, undefined), Bin0),
        IndexMap  = find_index_map(CMap, Bin0),
        CffMap = pp_cff(Cff, Bin0, Filename),
        (Loca == undefined orelse Glyf == undefined)
            andalso CffMap == undefined
            andalso throw({error, no_glyf_info}),
        Skip = Head+50,
        <<_:Skip/binary, LocFormat:?U16, ?SKIP>> = Bin0,
        #ttf_info{data = Bin0, file = Filename, collection = Index,
                  name = Name, os2 = Os2,
                  num_glyphs = NumGlyphs,
                  loca = Loca, glyf = Glyf,
                  cff = CffMap,
                  head = Head, hhea = Hhea, vhea = Vhea,
                  hmtx = Hmtx, kern = Kern, gpos = Gpos,
                  index_map = IndexMap,
                  index_to_loc_format = LocFormat
                 }
    catch error:_Err:_ST ->
            %% We create a bad tff_info here to give other user error messages
            %% than file not found
            ?DBG("Parse error: ~p~n~P:~n  ~P~n",[Filename, _Err,30,_ST, 100]),
            error({error, parse_error,
                   #ttf_info{name=Name, os2=Os2, data=Bin0,
                             file = {error, parse_error, Filename}}});
          throw:{error,_Err} ->
            ?DBG("Tabs: ~0.p~n",[maps:keys(Tabs)]),
            throw({error,_Err,
                   #ttf_info{name=Name, os2=Os2, data=Bin0,
                             file = {error, _Err, Filename}}})
    end.

get_font_v_metrics(#{ref := Ref}) ->
    [{_,TTF}] =  ets:lookup(?MODULE, {cache, Ref}),
    get_font_v_metrics(TTF);
get_font_v_metrics(#ttf_info{data=Bin, head=_Head, hhea = Hhea}) ->
    %% <<_:Head/binary, _:36/binary, X0:?S16, Y0:?S16, X1:?S16, Y1:?S16, ?SKIP>> = Bin,
    %% io:format("~p~n",[[X0,Y0,X1,Y1]]),
    <<_:Hhea/binary, _:4/binary, Ascent:?S16, Descent:?S16, LineGap:?S16, ?SKIP>> = Bin,
    %% io:format("~p ~p~n",[[M1, M2], M1-M2]),
    {Ascent, Descent, LineGap}.



%% format_error(Error) ->
%%     io:format("TFF error: ~p~n", [Error]),
%%     "Unsupported ttf format".

find_font_info(File) ->
    {ok,Filecontents} = file:read_file(File),
    find_font_info(Filecontents, File).

find_font_info(<<"ttcf", 0,_V,0,0, N:32, ?SKIP >> = Bin, File) ->
    %% ?DBG("Version ~w: Size ~w~n",[V,N]),
    Info = fun(Idx, Acc) ->
                   try
                       Font = init_font_1(File, Bin, Idx),
                       [find_font_info_1(Font)|Acc]
                   catch throw:_Reason ->
                           ?DBG("~s:~w: ~p~n", [File, Idx, _Reason]),
                           Acc
                   end
           end,
    lists:foldl(Info, [], lists:seq(0,N-1));
find_font_info(Bin, File) ->
    try init_font_1(File, Bin,0) of
        Font ->
            [find_font_info_1(Font)]
    catch throw:{error, Reason, #ttf_info{}=Font} ->
            ?DBG("~s: ~p~n", [File, Reason]),
            [{error, Reason, find_font_info_1(Font)}]
    end.

find_font_info_1(#ttf_info{file=_File, collection=_Coll} = TTF) ->
    FontInfo = font_info(TTF),
    Family = proplists:get_value(family, FontInfo, undefined),
    PrefFamily = proplists:get_value(preferred_family, FontInfo, undefined),
    {Style, Weight} = font_styles(TTF),
    %% ?DBG("~p (~w) ~p ~s ~s~n  ~0.p~n~n", [_File, _Coll, Family, Style, Weight, FontInfo]),
    %% io:format("File: ~p ~p ~p ~p ~p~n", [_File,Family, PrefFamily, Style, Weight]),
    case PrefFamily of
        undefined -> {Family, Family, Style, Weight};
        _ -> {Family, PrefFamily, Style, Weight}
    end.

check_enc(A, A) -> true;
check_enc({unicode,_}, unicode) -> true;
check_enc({unicode,_,_}, unicode) -> true;
check_enc(_, _) -> false.

string(String, roman) ->
    unicode:characters_to_list(String, latin1);
string(String, {unicode, _}) ->
    unicode:characters_to_list(String, utf16);
string(String, {unicode, bmp, _}) ->
    unicode:characters_to_list(String, utf16);
string(String, {unicode, full, _}) ->
    unicode:characters_to_list(String, utf32);
string(String, _) ->
    String.

font_styles(#ttf_info{data=Bin, os2=TabOffset}) when is_integer(TabOffset) ->
    <<_:TabOffset/binary,_Ver:16,_:16,Weight:?U16,_Pad:26/binary,
      _Panose:10/binary,_ChrRng:16/binary,_VenId:4/binary,
      FsSel:16,_T1/binary>> = Bin,
    FStyle = if (FsSel band ?fsITALIC) =:= ?fsITALIC -> italic;
                true -> normal
             end,
    FWeight = if
                  Weight < 150 -> light;  %% thin
                  Weight < 250 -> light;  %% extra-light
                  Weight < 350 -> light;
                  Weight < 450 -> normal;
                  Weight < 550 -> normal; %% medium
                  Weight < 650 -> bold; %% semi-bold
                  Weight < 750 -> bold;
                  Weight < 850 -> bold; %% extra-bold
                  true -> bold %% black
              end,
    {FStyle, FWeight};
font_styles(_) ->
    {normal, normal}.

%% Return the requested string from font
%% By default font family and subfamily (if not regular)
font_info(Font) ->
    StdInfoItems = [info(1),info(2),info(3),info(4),info(16),info(17)],
    Try = [{StdInfoItems, microsoft, unicode, english},
	   {StdInfoItems, unicode, unicode, 0},
	   {StdInfoItems, mac, roman, english}
	  ],
    font_info_2(Font, Try).

font_info_2(Font, [{Id,Platform,Enc,Lang}|Rest]) ->
    case font_info(Font, Id, Platform, Enc, Lang) of
	[] -> font_info_2(Font, Rest);
	Info -> Info
    end.

%% Return the requested string from font
%% Info Items: 1,2,3,4,16,17 may be interesting
%% Returns a list if the encoding is known otherwise a binary.
%% Return the empty list is no info that could be matched is found.
-spec font_info(Font::ttf(),
		[InfoId::integer()],
		Platform::platform(),
		Encoding::encoding(),
		Language::language()) -> [{InfoId::integer, string()}].
font_info(#ttf_info{data=Bin, name=Name}, Id, Platform, Encoding, Language) ->
    <<_:Name/binary, _V:16, Count:?U16, StringOffset:?U16, FI/binary>> = Bin,
    <<_:Name/binary, _:StringOffset/binary, Strings/binary>> = Bin,
    get_font_info(Count, FI, Strings, Id, Platform, Encoding, Language).

get_font_info(0, _, _, _, _, _, _) -> [];
get_font_info(N, <<PId:?U16, EId:?U16, LId:?U16, NId:?U16,
		   Length:?U16, StrOffset:?U16, Rest/binary>>, Strings,
	      WIds, WPlatform, WEnc, WLang) ->
    <<_:StrOffset/binary, String:Length/binary, ?SKIP>> = Strings,
    Platform = platform(PId),
    Encoding = encoding(EId, Platform),
    Lang = language(LId, Platform),
    Enc = check_enc(Encoding, WEnc),
    case lists:member(info(NId), WIds) of
	true when Platform =:= WPlatform, Enc, Lang =:= WLang ->
	    [{info(NId), string(String, Encoding)}|
	     get_font_info(N-1, Rest, Strings, WIds, WPlatform, WEnc, WLang)];
	_ ->
	    get_font_info(N-1, Rest, Strings, WIds, WPlatform, WEnc, WLang)
    end.

get_font_from_offset(<<"ttcf", 0,_V,0,0, N:32, Rest0/binary >> = Bin, Index)
  when N > Index ->
    Pos = Index*4,
    <<_:Pos/binary, Offset:32, ?SKIP>> = Rest0,
    <<_:Offset/binary, TTF/binary>> = Bin,
    TTF;
get_font_from_offset(Bin, 0) ->
    Bin.

find_font_file(Table, FontInfo) ->
    try
        #{face:=FName} = FontInfo,
        FStyle = maps:get(style, FontInfo, normal),
        FWeight = maps:get(weight, FontInfo, normal),
        Alternatives = find_font_file_0(Table, FName, true),
        %% ?DBG("~p => ~p~n", [FontInfo, Alternatives]),
        File = select_fontfile(Alternatives, FStyle, FWeight),
        ?DBG("FontFile: ~p~n", [File]),
        {FontInfo, {FName, File}}
    catch _:Er:St ->
            io:format("~p: ~p~n",[Er,St]),
            {FontInfo, undefined}
    end.

find_font_file_0(Tab, [$@|FName], TryWin) ->
    %% Some fonts in windows start with a '@' do know why
    %% but they can't be found so remove '@'
    find_font_file_0(Tab, FName, TryWin);
find_font_file_0(Tab, FName, TryWin) ->
    case ets:match_object(Tab, {{FName,'_', '_', '_'}, '_'}) of
        [] ->
            case ets:match_object(Tab, {{'_', FName, '_', '_'},'_'}) of
                [] when TryWin ->
                    find_font_file_1(Tab, FName);
                List ->
                    List
            end;
        List ->
            List
    end.

find_font_file_1(Table,FName) ->
    case winregval("FontSubstitutes",FName) of
        none -> [];
        FSName -> find_font_file_0(Table, FSName, false)
    end.

select_fontfile(Alts0, Style, Weight) ->
    Alts = case [FI || {{_,_,S,_}, _} = FI <- Alts0, S =:= Style] of
               [] ->
                   case [FI || {{_,_,normal,_}, _} = FI <- Alts0] of
                       [] -> Alts0;
                       As -> As
                   end;
               As -> As
           end,
    select_fontfile_1(Alts, Weight).

select_fontfile_1(Alts0, Weight) ->
    Alts = case [FI || {{_,_,_, W}, _} = FI <- Alts0, W =:= Weight] of
               [] ->
                   case [FI || {{_,_,_,normal}, _} = FI <- Alts0] of
                       [] -> Alts0;
                       As -> As
                   end;
               As -> As
           end,
    select_fontfile_2(Alts).

select_fontfile_2([]) ->
    undefined;
select_fontfile_2([{_, File}|R] = _Alts) ->
    R =/= [] andalso ?DBG("Selecting hd of ~p~n",[_Alts]),
    File.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

find_tables(<<_:32, NumTables:?U16, _SR:16, _ES:16, _RS:16, Tables/binary>>) ->
    find_table(NumTables, Tables, []).

find_table(0, _, Tabs) -> maps:from_list(Tabs);
find_table(Num, <<Tag:4/binary, _CheckSum:32, Offset:32, _Len:32, Next/binary>>, Tabs) ->
    find_table(Num-1, Next, [{Tag, Offset}|Tabs]).

num_glyphs(undefined, _Bin) ->
    16#ffff;
num_glyphs(Offset0, Bin) ->
    Offset = Offset0+4,
    <<_:Offset/binary, NG:?U16, ?SKIP>> = Bin,
    NG.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

find_index_map(Cmap, Bin) ->
    <<_:Cmap/binary, _:16, NumTables:?U16, Data/binary>> = Bin,
    case find_index_map1(NumTables, Data, []) of
        [] -> throw({error, supported_index_map_not_found});
        Alternatives ->
            [{_, Offset}|_] = lists:sort(Alternatives),
            %% ?DBG("Index maps: ~p + ~p => ~p~n", [Cmap,lists:sort(Alternatives),Cmap + Offset]),
            Cmap + Offset
    end.

find_index_map1(0,  _, Res) -> Res;
find_index_map1(N, <<?PLATFORM_ID_MICROSOFT:?U16, Enc:?U16, Offset:?U32, Rest/binary>>, Prev) ->
    case Enc of
        ?MS_EID_UNICODE_BMP ->
            find_index_map1(N-1, Rest, [{5, Offset}|Prev]);
        ?MS_EID_UNICODE_FULL ->
            find_index_map1(N-1, Rest, [{1, Offset}|Prev]);
        _ -> %% For example ?MS_EID_SYMBOL
            ?DBG("Ignored: ~w ~p~n",[Enc, encoding(Enc, microsoft)]),
            find_index_map1(N-1, Rest, Prev)
    end;
find_index_map1(N, <<?PLATFORM_ID_UNICODE:?U16, Enc:?U16, Offset:?U32, Rest/binary>>, Prev) ->
    case Enc of
        5 -> %% Cmap format 14 (we don't support that)
            ?DBG("Ignored: ~w ~p~n",[Enc, encoding(Enc, unicode)]),
            find_index_map1(N-1, Rest, Prev);
        4 ->
            find_index_map1(N-1, Rest, [{0, Offset}|Prev]);
        3 ->
            find_index_map1(N-1, Rest, [{4, Offset}|Prev]);
        6 ->
            find_index_map1(N-1, Rest, [{2, Offset}|Prev]);
        _ ->
            find_index_map1(N-1, Rest, [{6, Offset}|Prev])
    end;
find_index_map1(NumTables, <<_:64, Next/binary>>, Res) ->
    find_index_map1(NumTables-1, Next, Res).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Converts UnicodeCodePoint to Glyph index
%% Glyph 0 is the undefined glyph
-spec find_glyph_index(Font::ttf(), Char::integer()) -> Glyph::integer().
find_glyph_index(#ttf_info{data=Bin, index_map=IndexMap, os2=_Os2}, UnicodeCP) ->
    <<_:IndexMap/binary, Fmt:?U16, Data/binary>> = Bin,
    find_glyph_index(Fmt, Data, UnicodeCP).

find_glyph_index(0, IndexMap, UnicodeCP) ->
    <<Bytes:?U16, _:16, _:UnicodeCP/binary, Index:8, ?SKIP>> = IndexMap,
    %% Format0: Apple byte encoding
    case UnicodeCP < (Bytes-6) of
        true -> Index;
        false -> ?DBG("No CP in range",[]), 0
    end;
find_glyph_index(4, IndexMap, UnicodeCP) ->
    %% Format4: 16 bit mapping
    <<_Len:16, _Lan:16, Format4/binary>> = IndexMap,
    format_4_index(Format4, UnicodeCP);
find_glyph_index(6, IndexMap, UnicodeCP) ->
    %% Format6: Dense 16 bit mapping
    <<_Len:16, _Lang:16, First:?U16, Count:?U16, IndexArray/binary>> = IndexMap,
    case UnicodeCP >= First andalso UnicodeCP < (First+Count) of
        false -> ?DBG("No CP in index range",[]), 0;
        true  ->
            Pos = (UnicodeCP - First)*2,
            <<_:Pos/binary, Index:?U16, ?SKIP>> = IndexArray,
            Index
    end;
find_glyph_index(Format, IndexMap, UnicodeCP)
  when Format =:= 12; Format =:= 13 ->
    %% Format12/13: Mixed 16/32 and pure 32 bit mappings
    <<_:16, _:32, _:32, Count:?U32, Groups/binary>> = IndexMap,
    format_32_search(0, Count, Groups, UnicodeCP, Format);
find_glyph_index(_Format, _IndexMap, _UnicodeCP) ->
    %% Format2: Mixed 8/16 bits mapping for Japanese, Chinese and Korean
    %% Format8: Mixed 16/32 and pure 32 bit mappings
    %% Format10: Mixed 16/32 and pure 32 bit mappings
    ?DBG("unsupported glyph format ~w~n",[_Format]),
    0.

format_4_index(_, Unicode) when Unicode >= 16#FFFF -> 0;
format_4_index(<<SegCountX2:?U16, SearchRange0:?U16, EntrySel:?U16,
		 RangeShift:?U16, Table/binary>>, Unicode) ->
    %% SegCount    = SegCountX2 div 2,
    SearchRange = SearchRange0 div 2,
    %% Binary Search
    <<EndCode:SegCountX2/binary, 0:16,
      StartCode:SegCountX2/binary,
      IdDelta:SegCountX2/binary,
      IdRangeOffset/binary  %% Also includes  GlyphIndexArray/binary
    >> = Table,

    %% they lie from endCount .. endCount + segCount
    %% but searchRange is the nearest power of two, so...
    RangeShift = SegCountX2 - SearchRange0,
    Search = case EndCode of
		 <<_:RangeShift/binary, Search0:?U16, ?SKIP>>
		   when Unicode >= Search0 ->
		     RangeShift;
		 _ -> 0
	     end,
    Item = format_4_search(EntrySel, Search-2, SearchRange, EndCode, Unicode),
    case EndCode of
	<<_:Item/binary, Assert:16, ?SKIP>> ->
	    true = Unicode =< Assert;
	_ -> exit(assert)
    end,
    <<_:Item/binary, Start:?U16, ?SKIP>> = StartCode,
    %% <<_:Item/binary, End:?U16, ?SKIP>> = EndCode,
    <<_:Item/binary, Offset:?U16, ?SKIP>> = IdRangeOffset,
    if
	Unicode < Start ->
            %% ?DBG("Unicode: ~w start ~w~n",[Unicode, Start]),
	    0;
	Offset =:= 0 ->
            <<_:Item/binary, Index:?S16, ?SKIP>> = IdDelta,
	    (Index + Unicode) rem 65536;
	true ->
	    Skip = Item + Offset + (Unicode - Start)*2,
	    <<_:Skip/binary, Index:?U16, ?SKIP>> = IdRangeOffset,
	    Index
    end.

format_4_search(EntrySel, Start, SearchRange, Bin, Unicode) when EntrySel > 0 ->
    Index = Start + SearchRange,
    case Bin of
	<<_:Index/binary, End:?U16, ?SKIP>> when Unicode > End ->
	    format_4_search(EntrySel-1, Start+SearchRange, SearchRange div 2, Bin, Unicode);
	_ ->
	    format_4_search(EntrySel-1, Start, SearchRange div 2, Bin, Unicode)
    end;
format_4_search(_, Search, _, _, _) ->
    Search+2.

format_32_search(Low, High, Groups, UnicodeCP, Format)
  when Low < High ->
    Mid = Low + ((High - Low) div 2),
    MidIndex = Mid*12,
    <<_:MidIndex/binary, Start:?U32, End:?U32, Glyph:?U32, ?SKIP>> = Groups,
    if
	UnicodeCP < Start ->
	    format_32_search(Low, Mid, Groups, UnicodeCP, Format);
	UnicodeCP > End ->
	    format_32_search(Mid+1, High, Groups, UnicodeCP, Format);
	Format =:= 12 ->
	    Glyph+UnicodeCP-Start;
	Format =:= 13 ->
	    Glyph
    end;
format_32_search(_, _, _, _, _) -> 0.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_glyf_offset(#ttf_info{num_glyphs=NumGlyphs}, Glyph)
  when Glyph > NumGlyphs ->
    ?DBG("Out of range ~p max: ~p~n",[Glyph, NumGlyphs]),
    -1;
get_glyf_offset(#ttf_info{index_to_loc_format=0, data=Bin, loca=Loca, glyf=Glyf}, Glyph) ->
    Skip = Glyph*2,
    <<_:Loca/binary, _:Skip/binary, G1:?U16, G2:?U16, ?SKIP>> = Bin,
    case G1 == G2 of
	true -> -1;
	false -> Glyf + G1 * 2
    end;
get_glyf_offset(#ttf_info{index_to_loc_format=1, data=Bin, loca=Loca, glyf=Glyf}, Glyph) ->
    Skip = Glyph*4,
    <<_:Loca/binary, _:Skip/binary, G1:?U32, G2:?U32, ?SKIP>> = Bin,
    case G1 == G2 of
	true -> -1; %% Length is zero
	false -> Glyf + G1
    end;
get_glyf_offset(#ttf_info{index_to_loc_format=_F}, _) ->
    ?DBG("unknown glyph map format: ~p~n",[_F]),
    -1.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% leftSideBearing is the offset from the current horizontal position
%% to the left edge of the character advanceWidth is the offset from
%% the current horizontal position to the next horizontal position
%% these are expressed in unscaled coordinates
-spec get_glyph_h_metrics(Font::ttf(), Glyph::integer()) ->
          { Advance::integer(),
            LeftSideBearing::integer()}.
get_glyph_h_metrics(#ttf_info{data=Bin, hhea=Hhea, hmtx=Hmtx}, Glyph) ->
    <<_:Hhea/binary, _:34/binary, LongHorMetrics:?U16, ?SKIP>> = Bin,
    case Glyph < LongHorMetrics of
	true ->
	    Skip = 4*Glyph,
	    <<_:Hmtx/binary, _:Skip/binary, Advance:?S16, LeftSideBearing:?S16, ?SKIP>> = Bin,
	    {Advance, LeftSideBearing};
	false ->
	    Skip1 = 4*(LongHorMetrics-1),
	    <<_:Hmtx/binary, _:Skip1/binary, Advance:?S16, ?SKIP>> = Bin,
	    Skip2 = 4*LongHorMetrics+2*(Glyph-LongHorMetrics),
	    <<_:Hmtx/binary, _:Skip2/binary, LeftSideBearing:?S16, ?SKIP>> = Bin,
	    {Advance, LeftSideBearing}
    end.

get_glyph_kern_advance(#ttf_info{data=Bin, gpos = GPos, kern = Kern}, Glyph1, Glyph2) ->
    if GPos /= undefined ->
            <<_:GPos/binary, GPosTable/binary>> = Bin,
            get_glyph_gpos_advance(GPosTable, Glyph1, Glyph2);
       Kern /= undefined ->
            <<_:Kern/binary, KernTable/binary>> = Bin,
            get_glyph_kern_info_advance(KernTable, Glyph1, Glyph2);
       true ->
            0
    end.

get_glyph_gpos_advance(GPos, Glyph1, Glyph2) ->
    <<Major:?U16, Minor:?U16, _:32, Offset:?U16, _/binary>> = GPos,
    <<_:Offset/binary, LookupCount:?U16, LookupTab/binary>> = GPos,
    if Major =/= 1; Minor =/= 0 ->
            0;
       true ->
            get_glyph_gpos_advance(0, LookupCount, LookupTab, Glyph1, Glyph2)
    end.

get_glyph_gpos_advance(I, N, List, Glyph1, Glyph2) when I < N ->
    <<_:(I*2)/binary, Offset:?U16, Tab/binary>> = List,
    <<_:(Offset-2)/binary, Type:?U16, _:16, SubCount:?U16, SubOffsets/binary>> = List,
    if Type =/= 2 ->
            get_glyph_gpos_advance(I+1, N, List, Glyph1, Glyph2);
       true ->
            get_glyph_gpos_advance1(0, SubCount, SubOffsets, Tab, Glyph1, Glyph2)
    end;
get_glyph_gpos_advance(_I, _N, _List, _Glyph1, _Glyph2) ->
    0.

get_glyph_gpos_advance1(Sti, N, SubOffsets, LookupTab, Glyph1, Glyph2) when Sti < N ->
    <<_:(Sti*2)/binary, Offset:?U16, _/binary>> = SubOffsets,
    <<_:Offset/binary, Table/binary>> = LookupTab,
    <<PosFormat:?U16, CoverageOffset:?U16, VFormat1:?U16, VFormat2:?U16, _/binary>> = Table,
    <<_:CoverageOffset/binary, Index/binary>> = Table,

    CovIndex = get_coverage_index(Index, Glyph1),
    if CovIndex == -1 ->
            get_glyph_gpos_advance1(Sti+1, N, SubOffsets, LookupTab, Glyph1, Glyph2);
       VFormat1 =/= 4 orelse VFormat2 =/= 0 ->
            0;
       PosFormat == 1 ->
            <<_:8/binary, PairSetCount:?U16, _:(10+2*CovIndex), PairValueTab/binary>> = Table,
            <<PairValueCount:?U16, PairValueArray/binary>> = PairValueTab,
            if CovIndex >= PairSetCount ->
                    0;
               true ->
                    Pick = fun(M) ->
                                   ValueRecordPairSizeInBytes = 2,
                                   Skip = (2+ValueRecordPairSizeInBytes)*M,
                                   <<_:Skip, Straw:?U16, Advance:?S16, _/binary>> = PairValueArray,
                                   {Straw, Straw, Advance, 0}
                           end,
                    get_glyph_search(0, PairValueCount-1, Glyph2, Pick)
            end;
       PosFormat == 2 ->
            <<_:8/binary, CDef1Offset:?U16, CDef2Offset:?U16, C1N:?U16, C2N:?U16, C1Recs/binary>> = Table,
            G1Class = get_glyph_class(CDef1Offset, Table, Glyph1),
            G2Class = get_glyph_class(CDef2Offset, Table, Glyph2),
            if G1Class < 0 orelse G1Class >= C1N -> 0;
               G2Class < 0 orelse G2Class >= C2N -> 0;
               true ->
                    Skip = (2*G1Class*C2N)+2*G2Class,
                    <<_:Skip, XAdvance:?S16, _/binary>> = C1Recs,
                    XAdvance
            end;
       true ->
            0
    end;
get_glyph_gpos_advance1(_Sti, _N, _SubOffsets, _LookupTab, _Glyph1, _Glyph2) ->
    0.

get_coverage_index(IndexBin, Glyph) ->
    case IndexBin of
        <<1:?U16, Count:?U16, Array/binary>> ->
            GetStraw = fun(M) ->
                               <<_:(2*M), Straw:?U16, _/binary>> = Array,
                               {Straw, Straw, M, -1}
                       end,
            get_glyph_search(0, Count-1, Glyph, GetStraw);
        <<2:?U16, Count:?U16, Array/binary>> ->
            GetStraw = fun(M) ->
                               <<_:(6*M), Start:?U16, End:?U16, Res:?U16, _/binary>> = Array,
                               {Start, End, Res+Glyph-Start, -1}
                       end,
            get_glyph_search(0, Count-1, Glyph, GetStraw);
        _ -> %% Unsupported
            -1
    end.

get_glyph_class(CDefOffset, Table, Glyph) ->
    case Table of
        <<_:CDefOffset/binary, 1:?U16, StartGlyphId:?U16, Count:?U16, Array/binary>> ->
            if Glyph >= StartGlyphId, Glyph < StartGlyphId+Count ->
                    Skip = 2*(Glyph-StartGlyphId),
                    <<_:Skip, Class:?U16, _/binary>> = Array,
                    Class;
               true ->
                    0
            end;
        <<_:CDefOffset/binary, 2:?U16, Count:?U16, Array/binary>> ->
            R = Count-1,
            GetStraw = fun(M) ->
                               <<_:(6*M), Start:?U16, End:?U16, Class:?U16, _/binary>> = Array,
                               {Start, End, Class, 0}
                       end,
            get_glyph_search(0, R, Glyph, GetStraw);
        _ -> %% Unsupported definition type, return an error.
            -1
    end.

get_glyph_kern_info_advance(Data, Glyph1, Glyph2) ->
    <<_:16, NoTabs:?U16, _:32, HFlag:?U16, R:?U16, _/binary>> = Data,
    %% ?DBG("~n~nKERN ~w ~w~n", [Glyph1, Glyph2]),
    Pick = fun(M) ->
                   <<_:(18+(M*6))/binary, Straw:?U32, Advance:?S16, _/binary>> = Data,
                   {Straw, Straw, Advance, 0}
           end,
    if NoTabs < 1 -> 0;  %% Need at least 1 table
       HFlag =/= 1 -> 0; %% Horizontal flag must be set
       true -> get_glyph_search(0, R-1, (Glyph1 bsl 16) bor Glyph2, Pick)
    end.

get_glyph_search(L, R, Needle, GetStraw)
  when L =< R ->
%%    ?DBG("~w ~w ~w~n", [L,R,Needle]),
    M = (L+R) bsr 1,
    {StrawStart, StrawEnd, Advance, _Error} = GetStraw(M),
    if Needle < StrawStart ->
            get_glyph_search(L, M-1, Needle, GetStraw);
       Needle > StrawEnd ->
            get_glyph_search(M+1, R, Needle, GetStraw);
       true ->
            Advance
    end;
get_glyph_search(_L, _R, _Needle, Fun) ->
    {_, _, _, Error} = Fun(0),
    Error.

%% Computes a scale factor to produce a font whose EM size is mapped to
%% 'pixels' tall.
-spec scale_for_mapping_em_to_pixels(map() | Font::ttf(), Size::number()) -> Scale::float().
scale_for_mapping_em_to_pixels(#{ref := Ref}, Size) ->
    [{_,TTF}] =  ets:lookup(?MODULE, {cache, Ref}),
    scale_for_mapping_em_to_pixels(TTF, Size);
scale_for_mapping_em_to_pixels(#ttf_info{data=Bin, head=Head}, Size) ->
    <<_:Head/binary, _:18/binary, UnitsPerEm:?U16, ?SKIP>> = Bin,
    Size / UnitsPerEm.

-spec get_glyph_box(Font::ttf(), Glyph::integer()) ->
          {X0::integer(),Y0::integer(),
           X1::integer(),Y1::integer()}.
get_glyph_box(#ttf_info{cff=CFF}, Glyph)
  when CFF =/= undefined ->
    ?DBG("Is CFF~n",[]),
    {_, _, All} = run_charstring(CFF, Glyph),
    bb_box(All);
get_glyph_box(TTF = #ttf_info{data=Bin, glyf=Glyf}, Glyph)
  when Glyf =/= undefined ->
    case get_glyf_offset(TTF, Glyph) of
	Offset when Offset > 0  ->
	    <<_:Offset/binary, _:16, X0:?S16, Y0:?S16, X1:?S16, Y1:?S16, ?SKIP>> = Bin,
	    {X0,Y0,X1,Y1};
        _ ->
            {0,0,0,0}
    end.

get_glyph_bitmap_box(Font, Glyph, Scale, ShiftX, ShiftY) ->
    {X0,Y0,X1,Y1} = get_glyph_box(Font, Glyph),
    %% io:format("~w: ~w ~w ~w~n",[?LINE, Scale, Y0, floor(-Y0*Scale)]),
    {floor(X0*Scale+ShiftX), floor(-Y1*Scale+ShiftY),
     ceil(X1*Scale+ShiftX), ceil(-Y0*Scale+ShiftY)}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_glyph_shape(Font::ttf(), Glyph::integer()) -> [Vertices::vertex()].
get_glyph_shape(#ttf_info{glyf=undefined}=TTF, Glyph) ->
    get_glyph_shape_tt2(TTF, Glyph);
get_glyph_shape(TTF, Glyph) ->
    get_glyph_shape_tt(TTF, Glyph, get_glyf_offset(TTF, Glyph)).

get_glyph_shape_tt(_TTF, _Glyph, Offset)
  when Offset < 0 -> [];
get_glyph_shape_tt(TTF = #ttf_info{data=Bin}, _Glyph, Offset) ->
    <<_:Offset/binary, NumberOfContours:?S16,
      _XMin:16, _YMin:16, _XMax:16, _YMax:16,
      GlyphDesc/binary>> = Bin,

    %% ?DBG("Glyph: ~p ~p c#~p ~p ~p~n",[_Glyph, Offset, NumberOfContours, {_XMin,_XMax}, {_YMin,_YMax}]),

    if NumberOfContours > 0 ->
	    %% Single Glyph
	    Skip = NumberOfContours*2 - 2,
	    <<_:Skip/binary, Last:?U16, InsLen:?U16, Instr/binary>> = GlyphDesc,
	    N = 1 + Last,
	    <<_:InsLen/binary, FlagsBin/binary>> = Instr,
	    %%io:format("Conts ~p ~p ~p~n",[NumberOfContours, InsLen, N]),
	    {Flags, XCoordsBin} = parse_flags(N, 0, FlagsBin, []),
	    {XCs, YCoordsBin} = parse_coords(Flags, XCoordsBin, 0, 2, []),
	    {YCs, _} = parse_coords(Flags, YCoordsBin, 0, 4, []),
	    N = length(Flags),
	    setup_vertices(Flags, XCs, YCs, GlyphDesc);
       NumberOfContours =:= -1 ->
	    %% Several Glyphs (Compound shapes)
	    get_glyph_shapes(GlyphDesc, TTF, []);
       NumberOfContours < -1 ->
	    throw({error, bad_ttf, "Unsupported TTF format"});
       NumberOfContours =:= 0 ->
	    []
    end.

parse_flags(N, 0, <<Flag:8, Rest/binary>>, Flags)
  when N > 0 ->
    case (Flag band 8) > 1 of
	false ->
	    parse_flags(N-1, 0, Rest, [Flag|Flags]);
        true ->
	    <<Repeat:8, Next/binary>> = Rest,
	    parse_flags(N-1, Repeat, Next, [Flag|Flags])
    end;
parse_flags(N, R, Rest, Flags = [Prev|_])
  when N > 0 ->
    parse_flags(N-1, R-1, Rest, [Prev|Flags]);
parse_flags(0, 0, Rest, Flags) -> {lists:reverse(Flags), Rest}.

%% repeat(0, _, Flags) -> Flags;
%% repeat(N, Flag, Flags) -> repeat(N-1, Flag, [Flag|Flags]).

parse_coords([Flag|Flags], <<DX:8, Coords/binary>>, X0, Mask, Xs)
  when (Flag band Mask) > 1, (Flag band (Mask*8)) > 1 ->
    X = X0+DX,
    parse_coords(Flags, Coords, X, Mask, [X|Xs]);
parse_coords([Flag|Flags], <<DX:8, Coords/binary>>, X0, Mask, Xs)
  when (Flag band Mask) > 1 ->
    X = X0-DX,
    parse_coords(Flags, Coords, X, Mask, [X|Xs]);
parse_coords([Flag|Flags], Coords, X, Mask, Xs)
  when (Flag band (Mask*8)) > 1 ->
    parse_coords(Flags, Coords, X, Mask, [X|Xs]);
parse_coords([_|Flags], <<DX:?S16, Coords/binary>>, X0, Mask, Xs) ->
    X = X0 + DX,
    parse_coords(Flags, Coords, X, Mask, [X|Xs]);
parse_coords([], Rest, _, _, Xs) ->
    {lists:reverse(Xs), Rest}.

setup_vertices(Flags, XCs, YCs, GlyphDesc) ->
    setup_vertices(Flags, XCs, YCs, GlyphDesc, 0, -1, {0,0}, false,false, []).

setup_vertices([Flag|Fs0], [X|XCs0], [Y|YCs0], GD, StartC, Index,
	       S0, WasOff, StartOff0, Vs0)
  when StartC < 2 ->
    Vs1 = case StartC of
	      0 -> Vs0; %% First
	      1 -> close_shape(Vs0, S0, WasOff, StartOff0)
	  end,
    %% Start new one
    <<Next0:?U16, NextGD/binary>> = GD,
    Next = Next0-Index,
    case (Flag band 1) =:= 0 of
	true when Fs0 =/= [] ->
	    StartOff = {X,Y}, %% Save for warparound
	    [FN|Fs1]  = Fs0,
	    [XN|Xcs1] = XCs0,
	    [YN|Ycs1] = YCs0,
	    {S,Skip,Fs,XCs,YCs} =
		case ((FN band 1) =:= 0) of
		    true -> %% Next is also off
			{{(X+XN) div 2, (Y+YN) div 2},0,
			 Fs0, XCs0, YCs0};
		    false ->
			{{XN, YN},1,Fs1,Xcs1,Ycs1}
		end,
	    %%io:format("SOff ~p ~p ~p~n",[(Flag band 1) =:= 0, S, Next]),
	    Vs = set_vertex(Vs1, move, S, {0,0}),
	    setup_vertices(Fs,XCs,YCs,NextGD,Next-Skip,Next0,S,false,StartOff,Vs);
	_ ->
	    S = {X,Y},
	    %%io:format("Start ~p ~p ~p~n",[(Flag band 1) =:= 0, S, Next]),
	    Vs = set_vertex(Vs1, move, S, {0,0}),
	    setup_vertices(Fs0,XCs0,YCs0,NextGD,Next,Next0,S,false,false,Vs)
    end;
setup_vertices([Flag|Fs], [X|XCs], [Y|YCs], GD, Next,Index,S,WasOff,StartOff,Vs0) ->
    %%io:format("~p ~p~n",[(Flag band 1) =:= 0, WasOff /= false]),
    case {(Flag band 1) =:= 0, WasOff} of
	{true, {Cx,Cy}} ->
	    %%  two off-curve control points in a row means interpolate an on-curve midpoint
	    Int = {(X+Cx) div 2, (Y+Cy) div 2},
	    Vs = set_vertex(Vs0, curve, Int, WasOff),
	    setup_vertices(Fs,XCs,YCs, GD, Next-1,Index,S,{X,Y}, StartOff, Vs);
	{true, false} ->
	    setup_vertices(Fs,XCs,YCs, GD, Next-1,Index,S,{X,Y}, StartOff, Vs0);
	{false,false} ->
	    Vs = set_vertex(Vs0, line, {X,Y}, {0,0}),
	    setup_vertices(Fs,XCs,YCs, GD, Next-1,Index,S,false, StartOff, Vs);
	{false,C} ->
	    Vs = set_vertex(Vs0, curve, {X,Y}, C),
	    setup_vertices(Fs,XCs,YCs, GD, Next-1,Index,S,false, StartOff, Vs)
    end;
setup_vertices([], [], [], _, _Next, _, S, WasOff, StartOff, Vs) ->
    lists:reverse(close_shape(Vs, S, WasOff, StartOff)).

close_shape(Vs0, S={SX,SY}, C={CX,CY}, SC={_SCX,_SCY}) ->
    Vs1 = set_vertex(Vs0, curve, {(SX+CX) div 2, (SY+CY) div 2}, C),
    set_vertex(Vs1, curve, S, SC);
close_shape(Vs, S, false, SC={_SCX,_SCY}) ->
    set_vertex(Vs, curve, S, SC);
close_shape(Vs, S, C={_CX,_CY}, false) ->
    set_vertex(Vs, curve, S, C);
close_shape(Vs, S, false, false) ->
    set_vertex(Vs, line, S, {0,0}).

set_vertex(Vs, Mode, Pos, C) ->
    %% io:format(" ~p ~p ~p~n",[Mode, Pos, C]),
    [#vertex{type=Mode, pos=Pos, c=C}|Vs].
set_vertex(Vs, Mode, Pos, C, C1) ->
    %% io:format(" ~p ~p ~p ~p~n", [Mode, Pos, C, C1]),
    [#vertex{type=Mode, pos=Pos, c=C, c1=C1}|Vs].

get_glyph_shapes(<<Flags:?S16, GidX:?S16, GlyphDesc0/binary>>, Font, Vs0) ->
    {ScaleInfo,GlyphDesc} = find_trans_scales(Flags, GlyphDesc0),
    Vs1 = get_glyph_shape(Font, GidX),
    Vs = scale_vertices(Vs1, ScaleInfo, Vs0),
    case (Flags band (1 bsl 5)) > 1 of
	true -> %% More Components
	    get_glyph_shapes(GlyphDesc, Font, Vs);
	false ->
	    lists:reverse(Vs)
    end.

find_trans_scales(Flags,
		  <<Mtx4:?S16, Mtx5:?S16, GlyphDesc/binary>>)
  when (Flags band 3) > 2 ->
    find_trans_scales(Flags, Mtx4, Mtx5, GlyphDesc);
find_trans_scales(Flags, <<Mtx4:8, Mtx5:8, GlyphDesc/binary>>)
  when (Flags band 2) > 1 ->
    find_trans_scales(Flags, Mtx4, Mtx5, GlyphDesc).
%% @TODO handle matching point
%%find_trans_scales(Flags, GlyphDesc0) ->

find_trans_scales(Flags, Mtx4, Mtx5, <<Mtx0:?S16, GlyphDesc/binary>>)
  when (Flags band (1 bsl 3)) > 1 ->
    %% We have a scale
    S = 1 / 16384,
    {calc_trans_scales(Mtx0*S, 0, 0, Mtx0*S, Mtx4, Mtx5),GlyphDesc};
find_trans_scales(Flags, Mtx4, Mtx5, <<Mtx0:?S16, Mtx3:?S16, GlyphDesc/binary>>)
  when (Flags band (1 bsl 6)) > 1 ->
    %% We have a X and Y scale
    S = 1 / 16384,
    {calc_trans_scales(Mtx0*S, 0, 0, Mtx3*S, Mtx4, Mtx5), GlyphDesc};
find_trans_scales(Flags, Mtx4, Mtx5,
		  <<Mtx0:?S16, Mtx1:?S16,
		    Mtx2:?S16, Mtx3:?S16, GlyphDesc/binary>>)
  when (Flags band (1 bsl 7)) > 1 ->
    %% We have a two by two
    S = 1 / 16384,
    {calc_trans_scales(Mtx0*S, Mtx1*S, Mtx2*S, Mtx3*S, Mtx4, Mtx5), GlyphDesc};
find_trans_scales(_, Mtx4, Mtx5, GlyphDesc) ->
    {calc_trans_scales(1.0, 0.0, 0.0, 1.0, Mtx4, Mtx5), GlyphDesc}.

calc_trans_scales(Mtx0, Mtx1, Mtx2, Mtx3, Mtx4, Mtx5) ->
    {math:sqrt(square(Mtx0)+square(Mtx1)),
     math:sqrt(square(Mtx2)+square(Mtx3)), Mtx0, Mtx1, Mtx2, Mtx3, Mtx4, Mtx5}.

scale_vertices([#vertex{pos={X,Y}, c={CX,CY}, type=Type}|Vs],
	       SI={M,N, Mtx0, Mtx1, Mtx2, Mtx3, Mtx4, Mtx5}, Acc) ->
    V = #vertex{type=Type,
		pos = {round(M*(Mtx0*X+Mtx2*Y+Mtx4)),
		       round(N*(Mtx1*X+Mtx3*Y+Mtx5))},
		c   = {round(M*(Mtx0*CX+Mtx2*CY+Mtx4)),
		       round(N*(Mtx1*CX+Mtx3*CY+Mtx5))}},
    scale_vertices(Vs, SI, [V|Acc]);
scale_vertices([], _, Acc) -> Acc.

square(X) -> X*X.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% CFF stuff

pp_cff(undefined, _Bin, _File) ->
    undefined;
pp_cff(CffIdx, Bin0, _DbgFontFile) ->
    <<_:CffIdx/binary,Cff/binary>> = Bin0,
    <<1, _MinorVsn, HeaderSz, ?SKIP>> = Cff,
    <<_:HeaderSz/binary, Cont0/binary>> = Cff,
    {_NameIdx,  Cont1} = cff_index(Cont0),
    {TopDictIdx, Cont2} = cff_index(Cont1),
    TopDict = get_cff_index(0, TopDictIdx),  %% OpenType only supports one
    %?DBG("Strings: ~.16b~n",[byte_size(Cff) - byte_size(Cont2)]),
    {_StringIdx, Cont3} = cff_index(Cont2),
    %?DBG("Global Subrs: ~.16b~n",[byte_size(Cff) - byte_size(Cont3)]),
    {Gsubrs, _Cont4} = cff_index(Cont3),
    CharStringsOff = get_cff_dict(17,TopDict),
    CsType = get_cff_dict({12,6},TopDict),
    FdArrayOff = get_cff_dict({12,36},TopDict),
    FdSelectOff = get_cff_dict({12,37},TopDict),
    if CsType =:= 2; CsType =:= [], CharStringsOff /= [] -> ok;
       true -> throw({error, bad_cff_cstype, "Not supported OTF (cff) format"})
    end,

    Fd = case FdArrayOff of
             [] -> undefined;
             _ when FdSelectOff =/= [] ->  %% Looks like a CID font?
                 <<_:FdArrayOff/binary, FdArrBin/binary>> = Cff,
                 {FontDicts, _} = cff_index(FdArrBin),
                 %% ?DBG("~s: ~p ~p ~p~n",[_DbgFontFile, FdArrayOff, FdSelectOff, size(Cff)]),
                 <<_:FdSelectOff/binary, FdSelectBin/binary>> = Cff,
                 {FontDicts, FdSelectBin};
             _ ->
                 throw({error, no_fd_select, "Not supported OTF (cff) format"})
         end,
    Subrs = cff_get_subrs(TopDict, Cff),
    %% ?DBG("ChStr ~p type ~p FdA ~p FdS ~p ~p~n",
    %%      [CharStringsOff, CsType, FdArrayOff, FdSelectOff, size(Cff)]),
    <<_:CharStringsOff/binary, CharSBin/binary>> = Cff,
    {CharStrings, _Rest} = cff_index(CharSBin),
    #{topDict => TopDict,
      gsubrs  => Gsubrs,
      subrs   => Subrs,
      charStrings => CharStrings,
      fdSel => Fd,
      cff => Cff
     }.

cff_get_subrs(Dict, Bin) ->
    case get_cff_dict(18, Dict) of
        [Size, Offset] when Size /= 0, Offset /= 0 ->
            %% ?DBG("~p ~p ~.16b~n",[Size, Offset, Offset]),
            <<_:Offset/binary, PrivDict:Size/binary, _Rest/binary>> = Bin,
            case get_cff_dict(19, PrivDict) of
                [] -> undefined;
                SubrsOffs0 ->
                    SubrsOffs = SubrsOffs0 + Offset,
                    <<_:SubrsOffs/binary, Subrs/binary>> = Bin,
                    {Index, _} = cff_index(Subrs),
                    Index
            end;
        _ ->
            undefined
    end.

cff_index(<<0:16, Rest0/binary>>) ->
    {undefined, Rest0};
cff_index(<<Count:16, OffSz:8, Rest0/binary>>) when 1 =< OffSz, OffSz =< 4 ->
    TabSz = OffSz*(Count+1), Bits = OffSz*8,
    %% io:format("~p ~p ~p ~p~n", [Count, OffSz, TabSz, Bits]),
    <<Offsets0:TabSz/binary, Rest1/binary>> = Rest0,
    Offsets = [OS-1 || << OS:Bits >> <= Offsets0],
    Last = lists:last(Offsets),
    %% io:format("~p ~p ~p ~p ~p~n", [Count, OffSz, TabSz, Bits, Last]),
    <<_:Last/binary, Rest/binary>> = Rest1,
    {{array:from_list(Offsets), Rest1}, Rest}.

get_cff_index(Idx, {Offsets, Bin}) ->
    Offset = array:get(Idx, Offsets),
    Sz = array:get(Idx+1, Offsets) - Offset,
    <<_:Offset/binary, Data:Sz/binary, ?SKIP>> = Bin,
    Data.

get_cff_index_count({Offsets, _Bin}) ->
    array:size(Offsets).

get_cff_dict(Key, Bin) ->
    get_ccf_dict(Bin, [], Key).

get_ccf_dict(<<Data, ?SKIP>>=Bin, Vals, Key)
  when Data >= 28 ->
    {Val, Rest} = ccf_dict_operand(Bin),
    get_ccf_dict(Rest, [Val|Vals], Key);
get_ccf_dict(<<Key, ?SKIP>>, Val, Key) ->
    dict_val(Val);
get_ccf_dict(<<12, Op, Rest/binary>>, Val, Key) ->
    case Key of
        {12,Op} -> dict_val(Val);
        _  -> get_ccf_dict(Rest, [], Key)
    end;
get_ccf_dict(<<_Key, Rest/binary>>, _Val, Key) ->
    %% io:format("Not found ~p: ~p~n",[_Key,_Val]),
    get_ccf_dict(Rest, [], Key);
get_ccf_dict(<<>>, [], _) ->
    [].

dict_val([{float, _Bin}]) ->
    throw({nyi, cff_float});
dict_val([Val]) ->
    Val;
dict_val(Vals) when is_list(Vals) ->
    lists:reverse(Vals).

ccf_dict_operand(<<28, Val:?S16, Rest/binary>>) ->
    {Val,Rest};
ccf_dict_operand(<<29, Val:?S32, Rest/binary>>) ->
    {Val,Rest};
ccf_dict_operand(<<30, Bin/binary>>) ->
    Rest = ccf_dict_skip_float(Bin),
    %% Sz = byte_size(Bin) - byte_size(Rest),
    %% <<FloatBin:Sz, ?SKIP>> = Rest,
    {{float, aFloatBin}, Rest};
ccf_dict_operand(<<B, Rest/binary>>)
  when 31 < B, B < 247 ->
    {B-139, Rest};
ccf_dict_operand(<<B0, B1, Rest/binary>>)
  when 31 < B0, B0 < 255 ->
    case B0 < 251 of
        true  -> {(B0-247)*256+B1+108, Rest};
        false -> {-(B0-251)*256-B1-108, Rest}
    end.

ccf_dict_skip_float(<<16#F:4, _:4, Rest/binary>>) -> Rest;
ccf_dict_skip_float(<<_:4, 16#F:4, Rest/binary>>) -> Rest;
ccf_dict_skip_float(<<_, Rest/binary>>) ->
    ccf_dict_skip_float(Rest).

get_glyph_subrs(Glyph, {FontDicts, <<Fmt, FdSelBin/binary>>}, Cff) ->
    FdSel = case Fmt of
                0 -> %% Untested !!!
                    <<_:Glyph/binary, FdSelByte, ?SKIP>> = FdSelBin,
                    FdSelByte;
                3 ->
                    <<NRanges:?S16, Start:?S16, Cont0/binary>> = FdSelBin,
                    get_glyph_fd(NRanges, Start, Glyph, Cont0)
            end,
    %% ?DBG("Subr Format ~p sel: ~p index: ~p~n",[Fmt, FdSel, get_cff_index(FdSel, FontDicts)]),
    cff_get_subrs(get_cff_index(FdSel, FontDicts), Cff).

get_glyph_fd(N, Start, Glyph, Bin) when N > 0 ->
    <<V:8, End:?U16, Cont/binary>> = Bin,
    case Start =< Glyph andalso Glyph < End of
        true  -> V;
        false -> get_glyph_fd(N-1, End, Glyph, Cont)
    end;
get_glyph_fd(_, _, _, _) ->
    throw({error, fd_not_found, "Not supported"}).

get_glyph_shape_tt2(#ttf_info{cff=CFF} = _TTF, Glyph) ->
    {_,_,All} = run_charstring(CFF, Glyph),
    lists:reverse(All).

run_charstring(#{charStrings := CharSs}=Cff,  Glyph) ->
    Ops = get_cff_index(Glyph, CharSs),
    State = Cff#{ %% Add the following temporary variables
                  in_header => true,
                  maskbits => 0,
                  has_subrs => false,
                  glyph => Glyph
                },
    %% ?DBG("Glyph: ~w ~P~n",[Glyph, Ops, 40]),
    {return, Res} = run_chars(Ops, [], State, csctx_new()),
    Res.

run_chars(Bin, Stack, State, Acc) ->
    %% ?DBG("~.16b (~w) ~w~n", [binary:first(Bin), length(Stack), Stack]),
    do_run_chars(Bin, Stack, State, Acc).

do_run_chars(<<16#13, Rest0/binary>>, Stack, #{maskbits:=MB0, in_header:=InH}=State, Acc)->
    %% Hintmask NYI
    MB = case InH of
             true ->  (length(Stack) div 2) + MB0;
             false -> MB0
         end,
    Skip = (MB + 7) div 8,
    <<_:Skip/binary, Rest/binary>> = Rest0,
    run_chars(Rest, [], State#{maskbits:=MB,in_header:=false}, Acc);
do_run_chars(<<16#14, Rest0/binary>>, Stack, #{maskbits:=MB0, in_header:=InH}=State, Acc) ->
    %% CNTRMASK
    MB = case InH of
             true  -> (length(Stack) div 2) + MB0;
             false -> MB0
         end,
    Skip = (MB + 7) div 8,
    <<_:Skip/binary, Rest/binary>> = Rest0,
    run_chars(Rest, [], State#{maskbits:=MB,in_header=>false}, Acc);
do_run_chars(<<Stem, Rest/binary>>, Stack, #{maskbits:=MB0}=State, Acc)
  when Stem =:= 16#01;   %% hstem
       Stem =:= 16#03;   %% vstem
       Stem =:= 16#12;   %% hstemhm
       Stem =:= 16#17 -> %% vstemhm
    MB = (length(Stack) div 2) + MB0,
    run_chars(Rest, [], State#{maskbits:=MB}, Acc);

do_run_chars(<<16#15, Rest/binary>>, [S2,S1|_], State, Acc0) ->
    %% rmoveto
    Acc = csctx_rmove_to(S1,S2,Acc0),
    run_chars(Rest, [], State#{in_header:=false}, Acc);
do_run_chars(<<16#04,Rest/binary>>, [S1|_], State, Acc0) ->
    %% vmoveto
    Acc = csctx_rmove_to(0, S1, Acc0),
    run_chars(Rest, [], State#{in_header:=false}, Acc);
do_run_chars(<<16#16,Rest/binary>>, [S1|_], State, Acc0) ->
    %% hmoveto
    Acc = csctx_rmove_to(S1, 0, Acc0),
    run_chars(Rest, [], State#{in_header:=false}, Acc);

do_run_chars(<<16#05,Rest/binary>>, Stack, State, Acc0) ->
    Acc = rlineto(reverse(Stack), Acc0),
    run_chars(Rest, [], State#{in_header:=false}, Acc);

do_run_chars(<<16#06,Rest/binary>>, Stack, State, Acc0) ->
    Acc = hlineto(reverse(Stack), Acc0),
    run_chars(Rest, [],  State#{in_header:=false}, Acc);
do_run_chars(<<16#07,Rest/binary>>, Stack, State, Acc0) ->
    Acc = vlineto(reverse(Stack), Acc0),
    run_chars(Rest, [],  State#{in_header:=false}, Acc);

do_run_chars(<<16#1E,Rest/binary>>, Stack, State, Acc0) ->
    Acc = vhcurveto(reverse(Stack), Acc0),
    run_chars(Rest, [],  State, Acc);
do_run_chars(<<16#1F,Rest/binary>>, Stack, State, Acc0) ->
    Acc = hvcurveto(reverse(Stack), Acc0),
    run_chars(Rest, [],  State, Acc);
do_run_chars(<<16#08,Rest/binary>>, Stack, State, Acc0) ->
    Acc = rrcurveto(reverse(Stack), Acc0),
    run_chars(Rest, [],  State, Acc);

do_run_chars(<<16#18,Rest/binary>>, Stack, State, Acc0) ->
    Acc = rrcurveline(reverse(Stack), Acc0),
    run_chars(Rest, [],  State, Acc);
do_run_chars(<<16#19,Rest/binary>>, Stack, State, Acc0) ->
    Acc = rrlinecurve(reverse(Stack), Acc0),
    run_chars(Rest, [],  State, Acc);

do_run_chars(<<16#1A,Rest/binary>>, Stack0, State, Acc0) ->
    [F|Stack1] = Stack = reverse(Stack0),
    Acc = case length(Stack) rem 2 of
              1 -> vvcurveto(Stack1, F, Acc0);
              0 -> vvcurveto(Stack, 0.0, Acc0)
          end,
    run_chars(Rest, [],  State, Acc);
do_run_chars(<<16#1B,Rest/binary>>, Stack0, State, Acc0) ->
    [F|Stack1] = Stack = reverse(Stack0),
    Acc = case length(Stack) rem 2 of
              1 -> hhcurveto(Stack1, F, Acc0);
              0 -> hhcurveto(Stack, 0.0, Acc0)
          end,
    run_chars(Rest, [],  State, Acc);

do_run_chars(<<16#0A,Rest/binary>>, [V|Stack0], State0, Acc0) ->
    {State1,Subrs} =
        case maps:get(has_subrs, State0) orelse maps:get(fdSel,State0, undefined) of
            true -> {State0, maps:get(subrs, State0)};
            undefined -> {State0, maps:get(subrs, State0)};
            FdSel ->
                #{cff := Cff, glyph := Glyph} = State0,
                GlSubrs = get_glyph_subrs(Glyph, FdSel, Cff),
                {State0#{has_subrs := true, subrs := GlSubrs}, GlSubrs}
        end,
    %%?DBG("Recurse ...~p~n",[Stack0]),
    case callsubr(V, Subrs, Stack0, State1, Acc0) of
        {subrr, Stack, State, Acc} ->
            %%?DBG("...done ~p~n",[Stack]),
            run_chars(Rest, Stack, State, Acc);
        {return, _} = Acc ->
            %%?DBG("...done return~n",[]),
            <<>> = Rest, %% Assert
            Acc
    end;
do_run_chars(<<16#1D,Rest/binary>>, [V|Stack0], #{gsubrs := GSubrs} = State0, Acc0) ->
    %%?DBG("Recurse ...~p~n",[Stack0]),
    case callsubr(V, GSubrs, Stack0, State0, Acc0) of
        {subrr, Stack, State, Acc} ->
            %%?DBG("...done ~p~n",[Stack]),
            run_chars(Rest, Stack, State, Acc);
        {return, _} = Acc ->
            %%?DBG("...done return~n",[]),
            <<>> = Rest, %% Assert
            Acc
    end;

do_run_chars(<<16#0B,Rest/binary>>, Stack, State, Acc) ->
    %% Return (subr)
    <<>> = Rest,
    {subrr, Stack, State, Acc};
do_run_chars(<<16#0E,Rest/binary>>, _, _State, Acc) ->
    %% endchar
    <<>> = Rest,
    {return, csctx_close_shape(Acc)};

do_run_chars(<<16#0C,B1,Rest/binary>>, Stack, State, Acc0) ->
    %% Two-byte Escape-seq
    Acc = run_char(B1,Stack,Acc0),
    run_chars(Rest, [], State, Acc);
do_run_chars(<<16#FF, Int:32, Rest/binary>>, Stack, State, Acc) ->
    run_chars(Rest, [Int/16#10000|Stack], State, Acc);
do_run_chars(Bin, Stack, State, Acc) ->
    try ccf_dict_operand(Bin) of
        {Val, Rest} ->
            run_chars(Rest, [Val|Stack], State, Acc)
    catch _:_ ->
            <<Byte, _/binary>> = Bin,
            io:format("Bad op: 16#~.16b ~p~n ~P~n ~P~nin ~P~n",
                      [Byte, Stack, State, 10, Acc, 20, Bin, 40]),
            throw({error, parse_error})
    end.

run_char(16#22, [Dx6,Dx5,Dx4,Dx3,Dy2,Dx2,Dx1], Acc0) ->
    %% hflex
    Acc = csctx_rccurve_to(Dx1,0,Dx2,Dy2,Dx3,0,Acc0),
    csctx_rccurve_to(Dx4,0,Dx5,-Dy2,Dx6,0,Acc);
run_char(16#23, [_Fd, Dy6,Dx6,Dy5,Dx5,Dy4,Dx4,Dy3,Dx3,Dy2,Dx2,Dy1,Dx1], Acc0) ->
    %% flex
    Acc = csctx_rccurve_to(Dx1,Dy1,Dx2,Dy2,Dx3,Dy3,Acc0),
    csctx_rccurve_to(Dx4,Dy4,Dx5,Dy5,Dx6,Dy6,Acc);
run_char(16#24, [Dx6,Dy5,Dx5,Dx4,Dx3,Dy2,Dx2,Dy1,Dx1], Acc0) ->
    %% hflex1
    Acc = csctx_rccurve_to(Dx1,Dy1,Dx2,Dy2,Dx3,0,Acc0),
    csctx_rccurve_to(Dx4,0,Dx5,Dy5,Dx6,-(Dy1+Dy2+Dy5),Acc);
run_char(16#25, [D6,Dy5,Dx5,Dy4,Dx4,Dy3,Dx3,Dy2,Dx2,Dy1,Dx1], Acc0) ->
    %% flex1
    Dx = Dx1+Dx2+Dx3+Dx4+Dx5,
    Dy = Dy1+Dy2+Dy3+Dy4+Dy5,
    {Dx6,Dy6} = case abs(Dx) > abs(Dy) of
                    true  -> {D6, -Dy};
                    false -> {-Dx, D6}
                end,
    Acc = csctx_rccurve_to(Dx1,Dy1,Dx2,Dy2,Dx3,Dy3,Acc0),
    csctx_rccurve_to(Dx4,Dy4,Dx5,Dy5,Dx6,Dy6,Acc).

callsubr(N0, Subrs, Stack, State, Acc) ->
    Count = get_cff_index_count(Subrs),
    Bias = if Count >= 33900 -> 32768;
              Count >= 1240  -> 1131;
              true -> 107
           end,
    N = N0+Bias,
    ((N < 0) orelse (N >= Count)) andalso
        throw({error, internal_error, "A bug is found"}),
    Bin = get_cff_index(N, Subrs),
    %% ?DBG("sub ~W~n",[Bin, 40]),
    run_chars(Bin, Stack, State, Acc).

rlineto([S0,S1|St], Acc) ->
    rlineto(St, csctx_rline_to(S0,S1,Acc));
rlineto([], Acc) -> Acc.

%% Note: hlineto/vlineto alternate horizontal and vertical
%% starting from a different place.
hlineto([S0|St], Acc0) ->
    vlineto(St, csctx_rline_to(S0, 0, Acc0));
hlineto([], Acc) -> Acc.

vlineto([S0|St], Acc0) ->
    hlineto(St, csctx_rline_to(0, S0, Acc0));
vlineto([], Acc) -> Acc.

%% Note: vhcurveto/hvcurveto alternate horizontal and vertical
%% starting from a different place.
vhcurveto([S0,S1,S2,S3|St], Acc0) ->
    S4 = case St of
             [Last]-> Last;
             _ -> 0.0
         end,
    Acc = csctx_rccurve_to(0, S0, S1, S2, S3, S4, Acc0),
    hvcurveto(St, Acc);
vhcurveto(_, Acc) -> Acc.

hvcurveto([S0,S1,S2,S3|St], Acc0) ->
    S4 = case St of
             [Last] -> Last;
             _ -> 0.0
         end,
    Acc = csctx_rccurve_to(S0, 0, S1, S2, S4, S3, Acc0),
    vhcurveto(St, Acc);
hvcurveto(_, Acc) -> Acc.

rrcurveto([S0,S1,S2,S3,S4,S5|St], Acc0) ->
    Acc = csctx_rccurve_to(S0,S1,S2,S3,S4,S5,Acc0),
    rrcurveto(St,Acc);
rrcurveto(_, Acc) -> Acc.

rrcurveline([S0,S1,S2,S3,S4,S5|St], Acc0) ->
    Acc = csctx_rccurve_to(S0,S1,S2,S3,S4,S5,Acc0),
    rrcurveline(St, Acc);
rrcurveline([S0,S1], Acc0) ->
    csctx_rline_to(S0, S1, Acc0).

rrlinecurve([S0,S1|St], Acc0)
  when length(St) >= 6 ->
    Acc = csctx_rline_to(S0, S1, Acc0),
    rrlinecurve(St, Acc);
rrlinecurve([S0,S1,S2,S3,S4,S5], Acc0) ->
    csctx_rccurve_to(S0,S1,S2,S3,S4,S5,Acc0).

vvcurveto([S0,S1,S2,S3|St], F, Acc0) ->
    Acc = csctx_rccurve_to(F,S0,S1,S2,0.0,S3,Acc0),
    vvcurveto(St, 0.0, Acc);
vvcurveto([], _, Acc) -> Acc.

hhcurveto([S0,S1,S2,S3|St], F, Acc0) ->
    Acc = csctx_rccurve_to(S0,F,S1,S2,S3,0.0,Acc0),
    hhcurveto(St, 0.0, Acc);
hhcurveto([], _, Acc) -> Acc.

csctx_new() ->
    {{0.0,0.0},{0.0,0.0},[]}.

csctx_close_shape({{Fx,Fy}=First, {X,Y}=XY, Shapes} = Acc) ->
    case Fx /= X orelse Fy /= Y of
        true ->
            {First, XY, set_vertex(Shapes, line, First, {0,0})};
        false ->
            Acc
    end.

csctx_rmove_to(Dx,Dy,Acc0) ->
    {_First, {X,Y}, Shs} = csctx_close_shape(Acc0),
    XY = {X+Dx,Y+Dy},
    {XY, XY, set_vertex(Shs, move, XY, {0,0})}.

csctx_rline_to(Dx,Dy,{First,{X,Y},Shs}) ->
    XY = {X+Dx,Y+Dy},
    {First, XY, set_vertex(Shs, line, XY, {0,0})}.

csctx_rccurve_to(Dx1,Dy1,Dx2,Dy2,Dx3,Dy3,{First,{X,Y},Shs}) ->
    Cx1 = X + Dx1,
    Cy1 = Y + Dy1,
    Cx2 = Cx1 + Dx2,
    Cy2 = Cy1 + Dy2,
    XY  = {Cx2 + Dx3,Cy2 + Dy3},
    {First, XY, set_vertex(Shs, cubic, XY, {Cx1,Cy1}, {Cx2,Cy2})}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% Look up value with Name in Windows registry,
%% first changing to key K under the "CurrentVersion" for Windows.
%% Return value as string, or the token "none" if any problems.
winregval(K, Name) ->
    case os:type() of
	{win32,Wintype} ->
	    case win32reg:open([read]) of
		{ok, RH} ->
		    W = case Wintype of nt -> "Windows NT" ; _ -> "Windows" end,
		    CVK = "\\hklm\\SOFTWARE\\Microsoft\\" ++ W
			++ "\\CurrentVersion",
		    K1 = case K of
			     "" -> CVK;
			     _ -> CVK ++ "\\" ++ K
			 end,
		    Val = case win32reg:change_key(RH, K1) of
			      ok ->
				  case win32reg:value(RH, Name) of
				      {ok, V} -> V;
				      _ -> none
				  end;
			      _ -> none
			  end,
		    win32reg:close(RH),
		    Val;
		_ -> none
	    end;
	_ ->
	    none
    end.

%% Try to find default system directory for fonts
sysfontdirs() ->
    sysfontdirs(os:type()).

sysfontdirs({win32,Wintype}) ->
    Def = case Wintype of
              nt -> "C:/winnt";
              _ -> "C:/windows"
          end,
    System = case winregval("", "SystemRoot") of
                 none -> Def;
                 Val -> Val
             end,
    UserInstalled = filename:join(filename:basedir(user_data, "Microsoft"), "Windows"),
    [filename:join(System, "Fonts"), filename:join(UserInstalled, "Fonts")];
sysfontdirs({unix,darwin}) ->
    Home = os:getenv("HOME"),
    ["/Library/Fonts", "/System/Library/Fonts/", filename:join(Home, "Library/Fonts")];
sysfontdirs({unix,_}) ->
    Home = os:getenv("HOME"),
    ["/usr/share/fonts/", "/usr/local/share/fonts",
     filename:join(Home, ".fonts"),
     filename:join(Home, ".local/share/fonts")].

default_font() ->
    default_font(os:type()).

default_font({win32, _}) ->
    foobar;
default_font({unix, _}) ->
    "Deja Wu".

