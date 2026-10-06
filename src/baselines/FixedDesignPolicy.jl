"""Deterministic, observation-independent design cycled from its first point."""
struct FixedDesignPolicy <: AbstractPolicy end

_at_fraction(bounds, fraction) = bounds[1] + fraction * (bounds[2] - bounds[1])
_contains_zero_fixed(bounds) = bounds[1] <= 0 <= bounds[2]

function _fixed_design(limits::ActionLimits)
    design = ExperimentAction[]
    x = limits.displacement_m
    v = limits.velocity_m_per_s
    accel = limits.drive_acceleration_m_per_s2
    freq = limits.drive_frequency_hz

    if _contains_zero_fixed(accel) && _contains_zero_fixed(freq)
        # Four unforced corner conditions span the permitted initial-condition ranges.
        for (xf, vf) in ((0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0))
            push!(design, ExperimentAction(initial_displacement_m=_at_fraction(x, xf),
                initial_velocity_m_per_s=_at_fraction(v, vf)))
        end
    end

    nonzero_amplitudes = filter(!=(0.0), (accel[1], accel[2]))
    if !isempty(nonzero_amplitudes) && freq[2] > 0
        # Driven settings span low/middle/high positive frequencies and both available signs.
        positive_lower = freq[1] > 0 ? freq[1] : freq[2] / 4
        frequencies = unique(_at_fraction((positive_lower, freq[2]), q) for q in (0.0, 0.5, 1.0))
        for amplitude in nonzero_amplitudes, frequency in frequencies
            push!(design, ExperimentAction(initial_displacement_m=_at_fraction(x, 0.5),
                initial_velocity_m_per_s=_at_fraction(v, 0.5),
                drive_acceleration_m_per_s2=amplitude, drive_frequency_hz=frequency))
        end
    end
    isempty(design) && throw(ArgumentError("public limits admit no valid fixed-design action"))
    design
end

function next_action(::FixedDesignPolicy, state::PublicState)
    state.remaining_budget > 0 || throw(ArgumentError("cannot choose an action with exhausted budget"))
    design = _fixed_design(state.limits)
    index = length(state.history) + 1
    design[mod1(index, length(design))]
end

policy_identity(::FixedDesignPolicy) = PolicyIdentity("fixed_design", version="v0")
policy_configuration(::FixedDesignPolicy) = (; design_rule="unforced_corners_then_signed_drive_frequency_sweep", cycling="repeat_from_first_point")
