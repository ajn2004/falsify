module V02PilotProtocol
export retry_infrastructure_attempt
"""A full-slot retry is allowed only before any accepted intervention was consumed."""
retry_infrastructure_attempt(classification,attempt_index,max_retries,interventions_used)=
    classification=="infrastructure"&&attempt_index<=max_retries&&interventions_used==0
end
