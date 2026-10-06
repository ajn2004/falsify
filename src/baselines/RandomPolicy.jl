"""Seeded non-adaptive selection from the public control ranges."""
mutable struct RandomPolicy <: AbstractPolicy
    seed::Int
    rng::MersenneTwister
    driven_probability::Float64
    function RandomPolicy(seed::Integer; driven_probability::Real=0.5)
        seed >= 0 || throw(ArgumentError("policy seed must be nonnegative"))
        isfinite(driven_probability) && 0 <= driven_probability <= 1 ||
            throw(ArgumentError("driven_probability must be finite and in [0, 1]"))
        new(Int(seed), MersenneTwister(seed), Float64(driven_probability))
    end
end

_contains_zero(bounds) = bounds[1] <= 0 <= bounds[2]
_sample_range(rng, bounds) = bounds[1] + rand(rng) * (bounds[2] - bounds[1])

function _has_unforced(limits::ActionLimits)
    _contains_zero(limits.drive_acceleration_m_per_s2) && _contains_zero(limits.drive_frequency_hz)
end
function _has_driven(limits::ActionLimits)
    (limits.drive_acceleration_m_per_s2[1] < 0 || limits.drive_acceleration_m_per_s2[2] > 0) &&
        limits.drive_frequency_hz[2] > 0
end

function _sample_nonzero(rng, bounds)
    candidates = filter(!=(0.0), (bounds[1], bounds[2]))
    isempty(candidates) && throw(ArgumentError("public limits contain no valid driven amplitude"))
    candidates[rand(rng, eachindex(candidates))]
end

function next_action(policy::RandomPolicy, state::PublicState)
    state.remaining_budget > 0 || throw(ArgumentError("cannot choose an action with exhausted budget"))
    limits = state.limits
    unforced, driven = _has_unforced(limits), _has_driven(limits)
    (unforced || driven) || throw(ArgumentError("public limits admit no valid drive configuration"))
    choose_driven = driven && (!unforced || rand(policy.rng) < policy.driven_probability)
    acceleration, frequency = if choose_driven
        (_sample_nonzero(policy.rng, limits.drive_acceleration_m_per_s2),
         _sample_range(policy.rng, (max(limits.drive_frequency_hz[1], nextfloat(0.0)), limits.drive_frequency_hz[2])))
    else
        (0.0, 0.0)
    end
    ExperimentAction(
        initial_displacement_m=_sample_range(policy.rng, limits.displacement_m),
        initial_velocity_m_per_s=_sample_range(policy.rng, limits.velocity_m_per_s),
        drive_acceleration_m_per_s2=acceleration, drive_frequency_hz=frequency)
end

policy_identity(::RandomPolicy) = PolicyIdentity("random", version="v0")
policy_seed(policy::RandomPolicy) = policy.seed
policy_configuration(policy::RandomPolicy) = (; seed=policy.seed, driven_probability=policy.driven_probability)
