with latest_run as (
    select model_name, run_id, trained_at, holdout_auc, code_version
    from {{ source('ml', 'model_runs') }}
    where status = 'SUCCEEDED'
    qualify row_number() over (partition by model_name order by trained_at desc) = 1
)

select
    s.model_name,
    s.entity_type,
    s.entity_id,
    s.score,
    s.score_band,
    s.explanation,
    s.scored_at,
    r.run_id,
    r.trained_at,
    r.holdout_auc,
    r.code_version
from {{ source('ml', 'model_scores') }} s
join latest_run r
  on r.run_id = s.run_id
qualify row_number() over (
    partition by s.model_name, s.entity_type, s.entity_id
    order by s.scored_at desc
) = 1
