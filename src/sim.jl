export  SimParams,
		DEFAULT_SIM_PARAMS,
       
        simulate!,
        propagate!,
        record_frame_loglikelihoods!,
        isdone,

        get_input_acceleration,
		get_input_turnrate,

        calc_sequential_moving_average,
		calc_weighted_moving_average

immutable SimParams
	sec_per_frame :: Float64
	n_euler_steps :: Int
	extracted_feature_cache :: ExtractedFeatureCache

	function SimParams(
		sec_per_frame :: Float64 = DEFAULT_SEC_PER_FRAME,
		n_euler_steps :: Int     = 10,
		extracted_feature_cache :: ExtractedFeatureCache = ExtractedFeatureCache()
		)

		@assert(sec_per_frame > 0.0)
		@assert(n_euler_steps > 0)

		new(sec_per_frame, n_euler_steps, extracted_feature_cache)
	end
end
const DEFAULT_SIM_PARAMS = SimParams()

function simulate!(
    basics          :: FeatureExtractBasicsPdSet,
    behavior        :: AbstractVehicleBehavior,
    carid           :: Int,
    validfind_start :: Int,
    validfind_end   :: Int;
    pdset_frames_per_sim_frame::Int=5,
    n_euler_steps   :: Int = 2
    )

    for validfind in validfind_start : pdset_frames_per_sim_frame : validfind_end
        action_lat, action_lon = select_action(basics, behavior, carid, validfind)
        propagate!(basics.pdset, basics.sn, validfind, carid, action_lat, action_lon, 
                   pdset_frames_per_sim_frame, n_euler_steps)
    end

    basics
end
function simulate!(
    basics          :: FeatureExtractBasicsPdSet,
    behavior_pairs  :: Vector{(AbstractVehicleBehavior,Int)}, # (behavior, carid)
    validfind_start :: Int,
    validfind_end   :: Int;
    pdset_frames_per_sim_frame::Int=5,
    n_euler_steps   :: Int = 2
    )

    for validfind in validfind_start : pdset_frames_per_sim_frame: validfind_end
        for (behavior,carid) in behavior_pairs
            if !isa(behavior, VehicleBehaviorNone)
                action_lat, action_lon = select_action(basics, behavior, carid, validfind)
                propagate!(basics.pdset, basics.sn, validfind, carid, action_lat, action_lon, 
                          pdset_frames_per_sim_frame, n_euler_steps)
            end
        end
    end

    basics
end
function simulate!{B<:AbstractVehicleBehavior}(
	simlog        :: Matrix{Float64}, # initialized appropriately
	behaviors     :: Vector{B},
	road          :: StraightRoadway,
	frameind      :: Int, # starting index within simlog
	params        :: SimParams = DEFAULT_SIM_PARAMS;
	runid         :: Int = rand(Int)
	)
	
	basics = FeatureExtractBasics(simlog, road, params.sec_per_frame, params.extracted_feature_cache, runid)
	n_euler_steps = params.n_euler_steps
	δt = basics.sec_per_frame / n_euler_steps

	numcars = get_ncars(simlog)
	@assert(length(behaviors) == numcars)

	while !isdone(simlog, frameind)

		for (carind,behavior) in enumerate(behaviors)
			if !isa(behavior, VehicleBehaviorNone)
				action_lat, action_lon = select_action(basics, behavior, carind, frameind)
				logindexbase = calc_logindexbase(carind)
				propagate!(basics.simlog, frameind, logindexbase, 
					       action_lat, action_lon, n_euler_steps, δt)
			end
		end

		frameind += 1
	end

	simlog
end
function simulate!{B<:AbstractVehicleBehavior}(
    simlogs::Vector{Matrix{Float64}},
    behaviors::Vector{B},
    road::StraightRoadway,
    history::Int,
    simparams :: SimParams = DEFAULT_SIM_PARAMS
    )

    for (i,simlog) in enumerate(simlogs)
        simulate!(simlog, behaviors[1:get_ncars(simlog)], road, history, simparams, runid = i)
    end
    simlogs
end

function record_frame_loglikelihoods!(
	simlog::Matrix{Float64},
	frameind::Int,
	logindexbase::Int,
	logl_lat::Float64 = NaN,
	logl_lon::Float64 = NaN,
	)

	#=
	Record extra values to the log for the given vehicle
	=#

	simlog[frameind, logindexbase + LOG_COL_LOGL_LAT] = logl_lat
	simlog[frameind, logindexbase + LOG_COL_LOGL_LON] = logl_lon

	simlog
end

get_input_acceleration(action_lon::Float64) = action_lon
function get_input_turnrate(action_lat::Float64, ϕ::Float64)
    phi_des = action_lat
    (phi_des - ϕ)*Features.KP_DESIRED_ANGLE
end

function _propagate_one_pdset_frame!(
    pdset         :: PrimaryDataset,
    sn            :: StreetNetwork,
    validfind     :: Int,
    carid         :: Int,
    action_lat    :: Float64,
    action_lon    :: Float64,
    n_euler_steps :: Int,
    )

    validfind_fut = jumpframe(pdset, validfind, 1)
    @assert(validfind_fut != 0)

    Δt = get_elapsed_time(pdset, validfind, validfind_fut)
    δt = Δt / n_euler_steps

    carind = carid2ind(pdset, carid, validfind)

    if !idinframe(pdset, carid, validfind_fut)
        add_car_to_validfind!(pdset, carid, validfind_fut)
    end
    carind_fut = carid2ind(pdset, carid, validfind_fut)

    x = get(pdset, :posGx, carind, validfind)
    y = get(pdset, :posGy, carind, validfind)
    θ = get(pdset, :posGyaw, carind, validfind)
    
    s = d = 0.0
    ϕ = get(pdset, :posFyaw, carind, validfind)

    velFx = get(pdset, :velFx, carind, validfind)
    velFy = get(pdset, :velFy, carind, validfind)
    v = hypot(velFx, velFy)

    for j = 1 : n_euler_steps

        a = get_input_acceleration(action_lon)
        ω = get_input_turnrate(action_lat, ϕ)

        v += a*δt
        θ += ω*δt
        x += v*cos(θ)*δt
        y += v*sin(θ)*δt

        proj = project_point_to_streetmap(x, y, sn)
        @assert(proj.successful)

        ptG = proj.curvept
        s, d, ϕ = pt_to_frenet_xyy(ptG, x, y, θ)
    end

    proj = project_point_to_streetmap(x, y, sn)
    @assert(proj.successful)

    ptG = proj.curvept
    laneid = int(proj.laneid.lane)
    tile = proj.tile
    seg = get_segment(tile, int(proj.laneid.segment))
    d_end = distance_to_lane_end(seg, laneid, proj.extind)

    if carind == CARIND_EGO
        frameind_fut = validfind2frameind(pdset, validfind_fut)
        sete!(pdset, :posGx, frameind_fut, x)
        sete!(pdset, :posGy, frameind_fut, y)
        sete!(pdset, :posGyaw, frameind_fut, θ)

        sete!(pdset, :posFx, frameind_fut, NaN) # this should basically never be used
        sete!(pdset, :posFy, frameind_fut, NaN) # this should also basically never be used
        sete!(pdset, :posFyaw, frameind_fut, ϕ)

        sete!(pdset, :velFx, frameind_fut, v*cos(ϕ)) # vel along the lane
        sete!(pdset, :velFy, frameind_fut, v*sin(ϕ)) # vel perpendicular to lane

        sete!(pdset, :lanetag, frameind_fut, LaneTag(tile, proj.laneid))
        sete!(pdset, :curvature, frameind_fut, ptG.k)
        sete!(pdset, :d_cl, frameind_fut, d)

        d_merge = distance_to_lane_merge(seg, laneid, proj.extind)
        d_split = distance_to_lane_split(seg, laneid, proj.extind)
        sete!(pdset, :d_merge, frameind_fut, isinf(d_merge) ? NA : d_merge)
        sete!(pdset, :d_split, frameind_fut, isinf(d_split) ? NA : d_split)

        nll, nlr = StreetNetworks.num_lanes_on_sides(seg, laneid, proj.extind)
        @assert(nll ≥ 0)
        @assert(nlr ≥ 0)
        sete!(pdset, :nll, frameind_fut, nll)
        sete!(pdset, :nlr, frameind_fut, nlr)

        lane_width_left, lane_width_right = marker_distances(seg, laneid, proj.extind)
        sete!(pdset, :d_mr, frameind_fut, (d <  lane_width_left)  ?  lane_width_left - d  : Inf)
        sete!(pdset, :d_ml, frameind_fut, (d > -lane_width_right) ?  d - lane_width_right : Inf)
    else

        setc!(pdset, :posGx, carind_fut, validfind_fut, x)
        setc!(pdset, :posGy, carind_fut, validfind_fut, y)
        setc!(pdset, :posGyaw, carind_fut, validfind_fut, θ)

        setc!(pdset, :posFx, carind_fut, validfind_fut, NaN) # this should basically never be used
        setc!(pdset, :posFy, carind_fut, validfind_fut, NaN) # this should also basically never be used
        setc!(pdset, :posFyaw, carind_fut, validfind_fut, ϕ)

        setc!(pdset, :velFx, carind_fut, validfind_fut, v*cos(ϕ)) # vel along the lane
        setc!(pdset, :velFy, carind_fut, validfind_fut, v*sin(ϕ)) # vel perpendicular to lane

        setc!(pdset, :lanetag,   carind_fut, validfind_fut, LaneTag(tile, proj.laneid))
        setc!(pdset, :curvature, carind_fut, validfind_fut, ptG.k)
        setc!(pdset, :d_cl,      carind_fut, validfind_fut, d)

        d_merge = distance_to_lane_merge(seg, laneid, proj.extind)
        d_split = distance_to_lane_split(seg, laneid, proj.extind)
        setc!(pdset, :d_merge, carind_fut, validfind_fut, isinf(d_merge) ? NA : d_merge)
        setc!(pdset, :d_split, carind_fut, validfind_fut, isinf(d_split) ? NA : d_split)

        nll, nlr = StreetNetworks.num_lanes_on_sides(seg, laneid, proj.extind)
        @assert(nll ≥ 0)
        @assert(nlr ≥ 0)
        setc!(pdset, :nll, carind_fut, validfind_fut, nll)
        setc!(pdset, :nlr, carind_fut, validfind_fut, nlr)

        lane_width_left, lane_width_right = marker_distances(seg, laneid, proj.extind)
        setc!(pdset, :d_mr, carind_fut, validfind_fut, (d <  lane_width_left)  ?  lane_width_left - d  : Inf)
        setc!(pdset, :d_ml, carind_fut, validfind_fut, (d > -lane_width_right) ?  d - lane_width_right : Inf)

        setc!(pdset, :id,        carind_fut, validfind_fut, carid)
        setc!(pdset, :t_inview,  carind_fut, validfind_fut, getc(pdset, :t_inview, carind, validfind) + Δt)
        # NOTE(tim): `trajind` is deprecated
    end

    pdset
end
function propagate!(
    pdset         :: PrimaryDataset,
    sn            :: StreetNetwork,
    validfind     :: Int,
    carid         :: Int,
    action_lat    :: Float64,
    action_lon    :: Float64,
    pdset_frames_per_sim_frame :: Int,
    n_euler_steps :: Int,
    )

    # println("\n")
    # println(pdset.df_ego_primary[validfind, :])
    # for i = 0 : pdset_frames_per_sim_frame
    #     carind = carid2ind(pdset, carid, validfind+i)
    #     velFx = get(pdset, "velFx", carind, validfind+i)
    #     velFy = get(pdset, "velFy", carind, validfind+i)
    #     v = hypot(velFx, velFy)
    #     println("$i) v = ", v)
    # end

    for jump = 0 : pdset_frames_per_sim_frame-1
        validfind_fut = jumpframe(pdset, validfind, jump)
        @assert(validfind_fut != 0)
        _propagate_one_pdset_frame!(pdset, sn, validfind_fut, carid, action_lat, action_lon, n_euler_steps)        
    end

    # carind = carid2ind(pdset, carid, validfind)
    # action_lat_after = Features._get(FUTUREDESIREDANGLE_250MS, pdset, sn, carind, validfind)
    # action_lon_after = Features._get(FUTUREACCELERATION_250MS, pdset, sn, carind, validfind)

    # println("\n")
    # for i = 0 : pdset_frames_per_sim_frame
    #     carind = carid2ind(pdset, carid, validfind+i)
    #     velFx = get(pdset, "velFx", carind, validfind+i)
    #     velFy = get(pdset, "velFy", carind, validfind+i)
    #     v = hypot(velFx, velFy)
    #     println("$i) v = ", v)
    # end

    # @printf("before: %10.6f %10.6f\n", action_lat, action_lon)
    # @printf("after:  %10.6f %10.6f\n", action_lat_after, action_lon_after)
    # println(pdset.df_ego_primary[validfind, :])
    # println(pdset.df_ego_primary[validfind+5, :])
    # println("\n")
    # exit()

    pdset
end
function propagate!(
	simlog        :: Matrix{Float64},
	frameind      :: Int,
	logindexbase  :: Int,
	action_lat    :: Float64,
	action_lon    :: Float64,
	n_euler_steps :: Int,
	δt            :: Float64,
	)

	# run physics on the given car at time frameind
	# place results in log for that car in frameind + 1

	simlog[frameind, logindexbase + LOG_COL_ACTION_LAT] = action_lat
	simlog[frameind, logindexbase + LOG_COL_ACTION_LON] = action_lon

	x = simlog[frameind, logindexbase + LOG_COL_X]
	y = simlog[frameind, logindexbase + LOG_COL_Y]
	ϕ = simlog[frameind, logindexbase + LOG_COL_ϕ]
	v = simlog[frameind, logindexbase + LOG_COL_V]

	for j = 1 : n_euler_steps
		
		a = get_input_acceleration(action_lon)
		ω = get_input_turnrate(action_lat, ϕ)

		v += a*δt
		ϕ += ω*δt
		x += v*cos(ϕ)*δt
		y += v*sin(ϕ)*δt
	end

	simlog[frameind+1, logindexbase + LOG_COL_X] = x
	simlog[frameind+1, logindexbase + LOG_COL_Y] = y
	simlog[frameind+1, logindexbase + LOG_COL_ϕ] = ϕ
	simlog[frameind+1, logindexbase + LOG_COL_V] = v

	simlog
end
function propagate!(
	simlog        :: Matrix{Float64},
	frameind      :: Int,
	logindexbase  :: Int,
	action_lat    :: Float64,
	action_lon    :: Float64,
	params        :: SimParams	
	)
	
	sec_per_frame = params.sec_per_frame
	n_euler_steps = params.n_euler_steps
	δt            = sec_per_frame / n_euler_steps

	propagate!(simlog, frameind, logindexbase, action_lat, action_lon, n_euler_steps, δt)
end
function propagate!(
	simlog        :: Matrix{Float64},
	frameind      :: Int,
	action_lat    :: Float64,
	action_lon    :: Float64,
	params        :: SimParams	
	)
	
	sec_per_frame = params.sec_per_frame
	n_euler_steps = params.n_euler_steps
	δt            = sec_per_frame / n_euler_steps

	for carind in get_ncars(simlog)
		propagate!(simlog, frameind, calc_logindexbase(carind), action_lat, action_lon, n_euler_steps, δt)
	end

	simlog
end

isdone(simlog::Matrix{Float64}, frameind::Int) = frameind >= size(simlog, 1)

function calc_sequential_moving_average(
	vec         :: AbstractArray{Float64}, # vector of values to smooth on
	index_start :: Int,                    # the present index; value must be already populated
	history     :: Int                     # the number of values to smooth over, (≥ 1)
	)

	# Sequential Moving Average: the average of the past n results

	@assert(history ≥ 1)

	clamped_history = min(history, index_start)
	index_low = index_start - clamped_history + 1

	retval = 0.0
	for i = index_low : index_start
		retval += vec[i]
	end
	retval / clamped_history
end
function calc_weighted_moving_average(
	vec         :: AbstractArray{Float64}, # vector of values to smooth on
	index_start :: Int,                    # the present index; value must be already populated
	history     :: Int                     # the number of values to smooth over, (≥ 1)
	)

	# Weighted Moving Average: the average of the past n results weighted linearly
	# ex: (3×f₁ + 2×f₂ + 1×f₃) / (3 + 2 + 1)

	@assert(history ≥ 1)

	clamped_history = min(history, index_start)
	index_low = index_start - clamped_history + 1

	retval = 0.0
	for i = index_low : index_start
		retval += vec[i] * (i - index_low + 1)
	end
	retval / (0.5clamped_history*(clamped_history+1))
end

function _reverse_smoothing_sequential_moving_average(
	vec::AbstractArray{Float64}, # vector of values originally smoothed on; 
	                             # with the most recent value having been overwritten with the smoothed value
	index_start::Int, # the present index; value must be already populated
	history::Int # the number of values to smooth over, (≥ 1)
	)

	# If the SMA is (f₁ + f₂ + f₃ + ...) / n
	# the reverse value is f₁ = n⋅SMA - f₂ - f₃ - ...

	@assert(history ≥ 1)

	clamped_history = min(history, index_start)
	index_low = index_start - clamped_history + 1

	smoothed_result = vec[index_start]

	retval = clamped_history * smoothed_result
	for i = index_low : index_start-1
		retval -= vec[i]
	end
	retval
end
function _reverse_smoothing_weighted_moving_average(
	vec::AbstractArray{Float64}, # vector of values originally smoothed on; 
	                             # with the most recent value having been overwritten with the smoothed value
	index_start::Int, # the present index; value must be already populated
	history::Int # the number of values to smooth over, (≥ 1)
	)

	# If the WMA is (3×f₁ + 2×f₂ + 1×f₃) / (3 + 2 + 1)
	# the reverse value is f₁ = [WMA * (3 + 2 + 1) - 2×f₂ - 1×f₃] / 3

	@assert(history ≥ 1)

	clamped_history = min(history, index_start)
	index_low = index_start - clamped_history + 1

	smoothed_result = vec[index_start]

	retval = (0.5clamped_history*(clamped_history+1)) * smoothed_result
	for i = index_low : index_start-1
		retval -= vec[i] * (i - index_low + 1)
	end
	retval / clamped_history
end

