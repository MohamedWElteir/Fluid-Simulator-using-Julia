using FFTW # Fast Fourier Transform
using WriteVTK
using ProgressMeter
using Interpolations
using LinearAlgebra
using CUDA

N_POINTS = 100
KINEMATIC_VISCOSITY = 0.0001
TIME_STEP_LENGTH = 0.01
N_TIME_STEPS = 200



function backtrace!(backtraced_positions,original_positions,direction)
    # Euler Step backwards in time and periodically clamp into [0.0, 1.0]
    backtraced_positions[:] = mod1.(original_positions - TIME_STEP_LENGTH * direction,1.0)
end

function interpolate_positions!(field_interpolated,field,interval_x,interval_y,interval_z,query_points_x,query_points_y,query_points_z)
    interpolator = LinearInterpolation((interval_x, interval_y, interval_z),field,)
    field_interpolated[:] = interpolator.(query_points_x, query_points_y, query_points_z)
end

function main()
    # Define the output directory
    output_directory = "CPL_Folder"

    # Create the output directory if it doesn't exist
    if !isdir(output_directory)
        mkdir(output_directory)
    end

    element_length = 1.0 / (N_POINTS - 1)
    x_interval = 0.0:element_length:1.0
    y_interval = 0.0:element_length:1.0
    z_interval = 0.0:element_length:1.0

    # Similar to meshgrid in NumPy list comprehension
    coordinates_x = [x for x in x_interval, y in y_interval, z in z_interval] 
    coordinates_y = [y for x in x_interval, y in y_interval, z in z_interval]
    coordinates_z = [z for x in x_interval, y in y_interval, z in z_interval]

    wavenumbers_1d = fftfreq(N_POINTS) .* N_POINTS

    wavenumbers_x = [k_x for k_x in wavenumbers_1d, k_y in wavenumbers_1d, k_z in wavenumbers_1d]
    wavenumbers_y = [k_y for k_x in wavenumbers_1d, k_y in wavenumbers_1d, k_z in wavenumbers_1d]
    wavenumbers_z = [k_z for k_x in wavenumbers_1d, k_y in wavenumbers_1d, k_z in wavenumbers_1d]
    wavenumbers_norm = [norm([k_x, k_y, k_z]) for k_x in wavenumbers_1d, k_y in wavenumbers_1d, k_z in wavenumbers_1d]

    decay = exp.(- TIME_STEP_LENGTH .* KINEMATIC_VISCOSITY .* wavenumbers_norm.^2)

    wavenumbers_norm[iszero.(wavenumbers_norm)] .= 1.0
    normalized_wavenumbers_x = wavenumbers_x ./ wavenumbers_norm
    normalized_wavenumbers_y = wavenumbers_y ./ wavenumbers_norm
    normalized_wavenumbers_z = wavenumbers_z ./ wavenumbers_norm

    # Define the forces
    force_x = 100.0 .* (
        ifelse.(
            (coordinates_x .> 0.2)
            .&
            (coordinates_x .< 0.3)
            .&
            (coordinates_y .> 0.45)
            .&
            (coordinates_y .< 0.52)
            .&
            (coordinates_z .> 0.45)
            .&
            (coordinates_z .< 0.52),
            1.0,
            0.0,
        )
        -
        ifelse.(
            (coordinates_x .> 0.7)
            .&
            (coordinates_x .< 0.8)
            .&
            (coordinates_y .> 0.48)
            .&
            (coordinates_y .< 0.55)
            .&
            (coordinates_z .> 0.48)
            .&
            (coordinates_z .< 0.55),
            1.0,
            0.0,

        )
    )

    # Preallocate all arrays
    backtraced_coordinates_x = zero(coordinates_x)
    backtraced_coordinates_y = zero(coordinates_y)
    backtraced_coordinates_z = zero(coordinates_z)

    velocity_x = zero(coordinates_x)
    velocity_y = zero(coordinates_y)
    velocity_z = zero(coordinates_z)

    velocity_x_prev = zero(velocity_x)
    velocity_y_prev = zero(velocity_y)
    velocity_z_prev = zero(velocity_z)

    velocity_x_fft = zero(velocity_x)
    velocity_y_fft = zero(velocity_y)
    velocity_z_fft = zero(velocity_z)
    pressure_fft = zero(coordinates_x)

    velocity_x_trajectory = []
    velocity_y_trajectory = []
    velocity_z_trajectory = []

    @showprogress "Timestepping ..." for iter in 1:N_TIME_STEPS

        # (1) Apply the forces
        time_current = (iter - 1) * TIME_STEP_LENGTH
        pre_factor = max(1 - time_current, 0.0)
        velocity_x_prev += TIME_STEP_LENGTH * pre_factor * force_x

        # (2) Self-Advection by backtracing and interpolation
        backtrace!(backtraced_coordinates_x, coordinates_x, velocity_x_prev)
        backtrace!(backtraced_coordinates_y, coordinates_y, velocity_y_prev)
        backtrace!(backtraced_coordinates_z, coordinates_z, velocity_z_prev)
        interpolate_positions!(
            velocity_x,
            velocity_x_prev,
            x_interval,
            y_interval,
            z_interval,
            backtraced_coordinates_x,
            backtraced_coordinates_y,
            backtraced_coordinates_z,
        )
        interpolate_positions!(
            velocity_y,
            velocity_y_prev,
            x_interval,
            y_interval,
            z_interval,
            backtraced_coordinates_x,
            backtraced_coordinates_y,
            backtraced_coordinates_z,
        )
        interpolate_positions!(
            velocity_z,
            velocity_z_prev,
            x_interval,
            y_interval,
            z_interval,
            backtraced_coordinates_x,
            backtraced_coordinates_y,
            backtraced_coordinates_z,
        )

        # (3.1) Transform into Fourier Domain
        velocity_x_fft = fft(velocity_x)
        velocity_y_fft = fft(velocity_y)
        velocity_z_fft = fft(velocity_z)

        # (3.2) Diffuse by low-pass filtering
        velocity_x_fft .*= decay
        velocity_y_fft .*= decay
        velocity_z_fft .*= decay

        # (3.3) Compute Pseudo-Pressure by Divergence in Fourier Domain
        pressure_fft = (
            velocity_x_fft .* normalized_wavenumbers_x
            +
            velocity_y_fft .* normalized_wavenumbers_y
            +
            velocity_z_fft .* normalized_wavenumbers_z
        )

        # (3.4) Project the velocities to be incompressible
        velocity_x_fft -= pressure_fft .* normalized_wavenumbers_x
        velocity_y_fft -= pressure_fft .* normalized_wavenumbers_y
        velocity_z_fft -= pressure_fft .* normalized_wavenumbers_z

        # (3.5) Transform back into spatial domain
        velocity_x = real(ifft(velocity_x_fft))
        velocity_y = real(ifft(velocity_y_fft))
        velocity_z = real(ifft(velocity_z_fft))

        # Advance in time
        velocity_x_prev = velocity_x
        velocity_y_prev = velocity_y
        velocity_z_prev = velocity_z

        # Save for visualization
        push!(velocity_x_trajectory, velocity_x)
        push!(velocity_y_trajectory, velocity_y)
        push!(velocity_z_trajectory, velocity_z)
    end

    # Update the path where VTK files are saved
    paraview_collection(joinpath(output_directory, "transient_vector")) do pvd
        @showprogress "Writing out to vtk ..." for iter in 1:N_TIME_STEPS
            vtk_grid(joinpath(output_directory, "timestep_$iter"), x_interval, y_interval, z_interval) do vtk
                vtk["velocity"] = (
                    velocity_x_trajectory[iter],
                    velocity_y_trajectory[iter],
                    velocity_z_trajectory[iter],
                )
                time = (iter - 1) * TIME_STEP_LENGTH
                pvd[time] = vtk
            end
        end
    end

end

main()
