## Copyright (c) 2013 Miguel Bazdresch
##
## This file is distributed under the 2-clause BSD License.

# llplot() is our workhorse plotting function
function llplot()
    global gnuplot_state
    global gaston_config

    # select current figure
    c = findfigure(gnuplot_state.current)
    if c == 0
        println("No current figure")
        return
    end
    fig = gnuplot_state.figs[c]
    config = fig.conf

    # if figure has no data, stop here
    if isempty(fig.isempty)
        return
    end

    # Reset gnuplot settable options.
    gnuplot_send("\nreset\n")

    # Build terminal setup string and send it to gnuplot
    gnuplot_send(termstring())

    # Datafile filename. This is where we store the coordinates to plot.
    # This file is then read by gnuplot to do the actual plotting. One file
    # per figure handle is used; this avoids polutting /tmp with too many files.
    filename = joinpath(tempdir(),
                        "gaston-$(gaston_config.tmpprefix)-$(fig.handle)")
    f = open(filename,"w")

    # Send appropriate coordinates and data to gnuplot, depending on
    # whether we are doing 2-d, 3-d or image plots.

    # 2-d plot: Z is empty or plostyle is {,rgb}image
    if isempty(fig.curves[1].Z) ||
        fig.curves[1].conf.plotstyle == "image" ||
        fig.curves[1].conf.plotstyle == "rgbimage"
        # create data file
        for i in fig.curves
            ps = i.conf.plotstyle
            if ps == "errorbars" || ps == "errorlines"
                if isempty(i.E.yhigh)
                    # ydelta (single error coordinate)
                    writedlm(f,[i.x i.y i.E.ylow],' ')
                else
                    # ylow, yhigh (double error coordinate)
                    writedlm(f,[i.x i.y i.E.ylow i.E.yhigh],' ')
                end
            elseif ps == "financebars"
                # data is written to tmparr, which is then written to disk
                tmparr = zeros(length(i.x),5)
                # output matrix
                for col = 1:length(i.x)
                    tmparr[col,1] = i.x[col]
                    tmparr[col,2] = i.F.open[col]
                    tmparr[col,3] = i.F.low[col]
                    tmparr[col,4] = i.F.high[col]
                    tmparr[col,5] = i.F.close[col]
                end
                writedlm(f,tmparr,' ')
            elseif ps == "image"
                # data is written to tmparr, which is then written to disk
                tmparr = zeros(length(i.x)*length(i.y),3)
                tmparr_row_index = 1  # index into tmparr row
                # output matrix
                for row = 1:length(i.y)
                    x = length(i.x)
                    for col = 1:length(i.x)
                        tmparr[tmparr_row_index,1] = i.x[col]
                        tmparr[tmparr_row_index,2] = i.y[row]
                        tmparr[tmparr_row_index,3] = i.Z[row,col]
                        tmparr_row_index = tmparr_row_index+1
                        x = x-1
                    end
                end
                writedlm(f,tmparr,' ')
            elseif ps == "rgbimage"
                # data is written to tmparr, which is then written to disk
                tmparr = zeros(length(i.x)*length(i.y), 5)
                tmparr_row_index = 1
                # output matrix
                for col = 1:length(i.x)
                    y = length(i.y)
                    for row = 1:length(i.y)
                        tmparr[tmparr_row_index,1] = i.x[col]
                        tmparr[tmparr_row_index,2] = i.y[row]
                        tmparr[tmparr_row_index,3] = i.Z[y,col,1]
                        tmparr[tmparr_row_index,4] = i.Z[y,col,2]
                        tmparr[tmparr_row_index,5] = i.Z[y,col,3]
                        tmparr_row_index = tmparr_row_index+1
                        y = y-1
                    end
                end
                writedlm(f,tmparr,' ')
            else
                writedlm(f,[i.x i.y],' ')
            end
            write(f,"\n\n")
        end
        close(f)
        # send figure configuration to gnuplot
        gnuplot_send_fig_config(config)
        # Send user command to gnuplot
        !isempty(fig.gpcom) && gnuplot_send(fig.gpcom)
        # send plot command to gnuplot
        gnuplot_send(linestr(fig.curves, "plot", filename))

    # 3-d plot: Z is not empty and plotstyle is not {,rgb}image
    elseif !isempty(fig.curves[1].Z) &&
            fig.curves[1].conf.plotstyle != "image" &&
            fig.curves[1].conf.plotstyle != "rgbimage"
        # create data file
        for i in fig.curves
            # data is written to tmparr, which is then written to disk
            tmparr = zeros(1, 3)
            tmparr_row_index = 1
            for row in 1:length(i.x)
                for col in 1:length(i.y)
                    tmparr[1,1] = i.x[row]
                    tmparr[1,2] = i.y[col]
                    tmparr[1,3] = i.Z[row,col]
                    writedlm(f,tmparr,' ')
                end
                write(f,"\n")
            end
            write(f,"\n\n")
        end
        close(f)
        # send figure configuration to gnuplot
        gnuplot_send_fig_config(config)
        # Send user command to gnuplot
        !isempty(fig.gpcom) && gnuplot_send(fig.gpcom)
        # send command to gnuplot
        gnuplot_send(linestr(fig.curves, "splot",filename))
    end

    # Make sure gnuplot is done; if terminal is text, read data
    # reset error handling
    err = ""
    gnuplot_state.gp_lasterror = err
    gnuplot_state.gp_error = false

    attempt_stderr = 20
    attempt_stdout = 100
    sleep_interval = 0.05
    sleep_increment = 1.2

    gnuplot_send("printerr \"GastonDone\"\n")
    sleep(sleep_interval)

    # wait for stderr channel to be ready
    si = sleep_interval
    count = 0
    while !isready(ChanStdErr)
        sleep(si)
        si = sleep_increment * si
        count = count + 1
        count > attempt_stderr &&
        error("Gnuplot is taking too long to respond.")
    end

    # read all data in channel
    si = sleep_interval
    while isready(ChanStdErr)
        err = err * take!(ChanStdErr)
        sleep(si)
        si = sleep_increment * si
    end

    # check for errors while plotting
    if err != "GastonDone\n"
        gnuplot_state.gp_lasterror = err
        gnuplot_state.gp_error = true
        @warn("Gnuplot returned an error message:\n  $err)")
    end

    # if there was no error and text terminal, read all data from stdout
    if err == "GastonDone\n"
        if (gaston_config.terminal ∈ term_text)
            # wait for stdout to be ready
            si = sleep_interval
            count = 0
            while !isready(ChanStdOut)
                sleep(si)
                si = sleep_increment * si
                count = count + 1
                count > attempt_stdout &&
                error("Gnuplot is taking too long to respond.")
            end
            svgdata = ""
            si = sleep_interval
            while isready(ChanStdOut)
                svgdata = svgdata * take!(ChanStdOut)
                sleep(si)
                si = sleep_increment * si
            end
            fig.svg = svgdata
        end
    end

    return nothing

end
