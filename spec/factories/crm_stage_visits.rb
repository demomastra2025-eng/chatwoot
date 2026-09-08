FactoryBot.define do
  factory :crm_stage_visit, class: 'Crm::StageVisit' do
    deal factory: :crm_deal
    account { deal.account }
    pipeline { deal.pipeline }
    stage { deal.stage }
    entered_at { Time.current }
    reliable_since { entered_at }
    estimated { false }
    pipeline_name { pipeline.name }
    stage_name { stage.name }
    stage_outcome { stage.outcome }
    correlation_id { SecureRandom.uuid }
  end
end
