# independent observables
inputfiles = Observable([""])
outputfolder = Observable("")
localizations = Observable(Dict{String, Dict{String, Vector{Localization}}}()) # vector for each channel in each image
selectedimg = Observable{Union{Nothing, Matrix{RGB{N0f8}}}}(nothing)
rois = Observable(Dict{String, Any}())
activedrawing = Observable(false)
polyroibuilder = Observable([])
nextlineposition = Observable{Union{Nothing, NTuple{2, Float64}}}(nothing)
selectedroi = Observable{Union{Nothing, Int}}(nothing)

# initialize UI elements
b = Gtk.GtkBuilder(filename="gui/clusdoc.glade")
imgcanvas = canvas(UserUnit, 500, 500)
push!(b["canvasbox"], imgcanvas)
win = b["mainwin"]

inputbtn = button(widget = b["inputbtn"])
inputtxt = textbox(String; widget = b["inputtxt"])
outputbtn = button(widget = b["outputbtn"])
textbox(String; widget = b["outputtxt"], observable = outputfolder)
fileselector = dropdown([], widget = b["fileselector"])
addroibtn = button(widget = b["roiadd"])
deleteroibtn = button(widget = b["roidelete"])
savebtn = button(widget = b["roisave"])
loadbtn = button(widget = b["roiload"])
runbtn = button(widget = b["runbtn"])

Gtk.GdkRGBA(c::RGBA) = Gtk.GdkRGBA(c.R, c.G, c.B, c.A)

ch1colorbtn = colorbutton(RGBA(0, 0, 0, 0.5); widget = b["ch1colorbutton"])
ch2colorbtn = colorbutton(RGBA(0, 0, 0, 0.5); widget = b["ch2colorbutton"])
ch3colorbtn = colorbutton(RGBA(0, 0, 0, 0); widget = b["ch3colorbutton"])

Gtk.showall(win)


# define event handlers
function loadfiles(_)
    files = pick_multi_file()
    if length(files) > 0
        inputfiles[] = files
    end
end

function vec_to_text(obs)
    if length(obs) > 0
        txt = "\"" * join(obs, "\" \"") * "\""
    else
        txt = ""
    end
    if txt != inputtxt[]
        inputtxt[] = txt
    end
end

function text_to_vec(obs)
    files = filter!(x -> !contains(x, r"^\s*$"), split(obs, "\"", keepempty = false))
    if files != inputfiles[]
        inputfiles[] = files
    end
end

function set_outputfolder(_)
    path = pick_folder()
    if path != ""
        outputfolder[] = joinpath(path, "ClusDoC Results")
    end
end

function populate_fileselector(obs)
    @idle_add begin
        empty!(fileselector)
        append!(fileselector, basename.(obs))
        fileselector[] = basename(inputfiles[][1])
    end
end

function load_data(obs)
    obs === nothing && return
    empty!(localizations[])
    for f ∈ inputfiles[]
        locs = loadlocalizations(f, LocalizationMicroscopy.nikonelementstext)
        fname = basename(f)
        localizations[][fname] = Dict{String, Vector{Localization}}()
        for chname ∈ unique(l.channel for l ∈ locs)
            localizations[][fname][chname] = filter(l -> l.channel == chname, locs)
        end
    end
    empty!(rois[])
    notify!(localizations)
    notify!(rois)
end

const colors = (:blue, :orange, :purple)

function drawplots(_)
    outputfolder[] == "" && return
    for f ∈ inputfiles[]
        filename = basename(f)
        haskey(localizations[], filename) || continue
        locs = localizations[][filename]
        generate_whole_localization_map(locs, outputfolder[], filename)
        # could probably generate plots, but delay saving until an output folder selected.
    end
    load_image(fileselector[])
end

function load_image(obs)
    if obs === nothing
        set_gtk_property!(ch1colorbtn.widget, :visible, false)
        set_gtk_property!(ch2colorbtn.widget, :visible, false)
        set_gtk_property!(ch3colorbtn.widget, :visible, false)
        return
    end
    try
        # may fire before images created
        selectedimg[] = load(joinpath(outputfolder[], obs * ".png"))
        
        chnames = sort(unique(keys(localizations[][fileselector[]])))
        set_gtk_property!(ch1colorbtn.widget, :label, chnames[1])
        set_gtk_property!(ch1colorbtn.widget, :visible, true)
        set_gtk_property!(ch2colorbtn.widget, :label, chnames[2])
        set_gtk_property!(ch2colorbtn.widget, :visible, true)
        if length(chnames) > 2
            set_gtk_property!(ch3colorbtn.widget, :label, chnames[3])
            set_gtk_property!(ch3colorbtn.widget, :visible, true)
        else
            set_gtk_property!(ch3colorbtn.widget, :visible, false)
        end
    catch ex
        if !(ex isa ArgumentError)
            rethrow()
        end
    end
end

function change_file(obs)
    selectedroi[] = nothing
end

function start_roi_drawing(obs)
    activedrawing[] = true
    selectedroi[] = nothing
end

function delete_roi(obs)
    deleteat!(rois[][fileselector[]], selectedroi[])
    selectedroi[] = nothing
end

function save_rois(obs)
    outputfolder !== "" || return
    roifile = joinpath(outputfolder[], "roicoordinates.txt")

    open(roifile, "w") do f
        for (filename, filerois) ∈ rois[]
            write(f, "#", filename, "\n")
            for roi ∈ filerois
                write(f, "\t")
                for p ∈ @view roi[1:end-1]
                    write(f, string(p), ",")
                end
                write(f, string(roi[end]), "\n")
            end
            write(f, "\n")
        end
    end
end

function load_rois(obs)
    # if file doesn't exist, ask for location
    outputfolder !== "" || return
    roifile = joinpath(outputfolder[], "roicoordinates.txt")

    if !isfile(roifile)
        roifile = pick_file()
    end
    isfile(roifile) || return
    roidict = Dict{String, Any}()
    open(roifile, "r") do f
        lines = readlines(f)
        filename = ""
        filerois = []
        for line ∈ lines
            if startswith(line, "#")
                if filename != ""
                    roidict[filename] = filerois
                    filerois = []
                end
                filename = only(split(line, "#", keepempty = false))
            elseif startswith(line, "\t") && filename != ""
                points = split.(
                    split(only(split(line, ('\t'), keepempty = false)), "),("),
                    Ref(('(', ',', ')')), keepempty = false)
                roi = [tuple(parse.(Float64, y)...) for y ∈ points]
                push!(filerois, roi)
            end
        end
        filename != "" && (roidict[filename] = filerois)
    end
    rois[] = roidict
end

function run_clusdoc(_)
    roicount = sum((n = length(get(rois[], basename(filename), [])); n == 0 ? 1 : n) for filename ∈ inputfiles[])
    progress = progressbar(0:roicount; widget = b["statusprogress"]) # won't update live unless user enables more than one thread
    #@idle_add Gtk.start(b["runspinner"]) # can't get spinner to appear at all, may be an SVG rendering or resource file issue 
    #Threads.@spawn
    clusdoc(inputfiles[], rois[], localizations[], outputfolder[], () -> @idle_add progress[] += 1)
    #Gtk.stop(b["runspinner"])
end


function draw_canvas(c, img, rois, newroi, nextlineposition, selectedroi)
    img !== nothing || return
    copy!(c, img)
    set_coordinates(c, BoundingBox(0, 1, 0, 1))
    ctx = Gtk.getgc(c)
    if haskey(rois, fileselector[])
        for (i, roi) ∈ enumerate(rois[fileselector[]])
            if i == selectedroi
                drawroi(ctx, roi, colorant"red")
            else
                drawroi(ctx, roi, colorant"gray")
            end
        end
    end
    nextpoly = nextlineposition === nothing ? newroi : [newroi; nextlineposition]
    drawroi(ctx, nextpoly, colorant"red", false)
end

function drawroi(ctx, roi, color, close = true)
    isempty(roi) && return
    p1 = first(roi)
    p = p1
    Gtk.move_to(ctx, p[1], p[2])
    Gtk.set_source(ctx, color)
    for i ∈ 2:length(roi)
        p = roi[i]
        Gtk.line_to(ctx, p[1], p[2])
    end
    close && Gtk.line_to(ctx, p[1], p[2])
    Gtk.stroke(ctx)
end

function onmouseclick(btn)
    if activedrawing[]
        if btn.button == 1 && btn.modifiers == 0
            push!(polyroibuilder[], (btn.position.x.val, btn.position.y.val))
            if btn.clicktype == DOUBLE_BUTTON_PRESS
                # two single-click events occur when a double-click event occurs
                pop!(polyroibuilder[])
                pop!(polyroibuilder[])
                push!(polyroibuilder[], polyroibuilder[][1])
                if haskey(rois[], fileselector[])
                    push!(rois[][fileselector[]], polyroibuilder[])
                else
                    rois[][fileselector[]] = [polyroibuilder[]]
                end
                polyroibuilder[] = []
                activedrawing[] = false
                nextlineposition[] = nothing
                notify!(rois)
            else
                notify!(polyroibuilder)
            end
        end
    else
        if haskey(rois[], fileselector[])
            filerois = collect(rois[][fileselector[]])
            pos = (btn.position.x.val, btn.position.y.val)
            matches = inpolygon.(Ref(pos), filerois) .!= 0
            if selectedroi[] === nothing
                selectedroi[] = findfirst(matches)
            else
                selectedroi[] = findnext(matches, selectedroi[] + 1)
                if selectedroi[] === nothing
                    selectedroi[] = findfirst(matches)
                end
            end
        end
    end
end

function onmousemove(btn)
    if activedrawing[]
        nextlineposition[] = (btn.position.x.val, btn.position.y.val)
    end
end


# hook up event handlers
on(loadfiles, inputbtn)
on(vec_to_text, inputfiles)
on(load_data, inputfiles)
on(populate_fileselector, inputfiles)
on(text_to_vec, inputtxt)
on(set_outputfolder, outputbtn)
on(drawplots, outputfolder)
on(drawplots, localizations)
on(load_image, fileselector)
on(change_file, fileselector)
on(start_roi_drawing, addroibtn)
on(delete_roi, deleteroibtn)
on(save_rois, savebtn)
on(load_rois, loadbtn)
on(run_clusdoc, runbtn)

draw(draw_canvas, imgcanvas, selectedimg, rois, polyroibuilder, nextlineposition, selectedroi)

on(onmouseclick, imgcanvas.mouse.buttonpress)
on(onmousemove, imgcanvas.mouse.motion)



# should have a colorset selector?

