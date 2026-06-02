FactoryBot.define do
  factory :captain_skill, class: 'Captain::Skill' do
    association :account
    sequence(:name) { |n| "Workspace Skill #{n}" }
    description { 'Reusable workspace skill' }
    content { 'Use this skill to answer consistently.' }
    group_name { 'Workspace Skills' }
    metadata { {} }
  end
end
