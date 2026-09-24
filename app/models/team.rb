# == Schema Information
#
# Table name: teams
#
#  id                :bigint           not null, primary key
#  allow_auto_assign :boolean          default(TRUE)
#  description       :text
#  name              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#
# Indexes
#
#  index_teams_on_account_id           (account_id)
#  index_teams_on_name_and_account_id  (name,account_id) UNIQUE
#
class Team < ApplicationRecord
  include AccountCacheRevalidator

  belongs_to :account
  has_many :team_members, dependent: :destroy_async
  has_many :members, through: :team_members, source: :user
  has_many :conversations, dependent: :nullify
  has_many :communication_threads, dependent: :nullify
  has_many :crm_deals, class_name: 'Crm::Deal', dependent: :nullify, inverse_of: :team
  has_many :crm_tasks, class_name: 'Crm::Task', dependent: :nullify, inverse_of: :team
  has_many :scheduling_resources, class_name: 'Scheduling::Resource', dependent: :nullify, inverse_of: :team
  has_many :scheduling_appointments, class_name: 'Scheduling::Appointment', dependent: :restrict_with_error, inverse_of: :team

  validates :name,
            presence: { message: I18n.t('errors.validations.presence') },
            uniqueness: { scope: :account_id }

  def self.lock_routing_targets!(account_id:, team_ids:)
    ids = Array(team_ids).compact.uniq
    where(account_id: account_id, id: ids).order(:id).lock('FOR KEY SHARE').load if ids.present?
  end

  before_destroy :record_communication_thread_nullifications, prepend: true

  before_validation do
    self.name = name.downcase if attribute_present?('name')
  end

  # Adds multiple members to the team
  # @param user_ids [Array<Integer>] Array of user IDs to add as members
  # @return [Array<User>] Array of newly added members
  def add_members(user_ids)
    team_members_to_create = user_ids.map { |user_id| { user_id: user_id } }
    created_members = team_members.create(team_members_to_create)
    added_users = created_members.filter_map(&:user)

    update_account_cache
    added_users
  end

  # Removes multiple members from the team
  # @param user_ids [Array<Integer>] Array of user IDs to remove
  # @return [void]
  def remove_members(user_ids)
    team_members.where(user_id: user_ids).destroy_all
    update_account_cache
  end

  def messages
    account.messages.where(conversation_id: conversations.pluck(:id))
  end

  def reporting_events
    account.reporting_events.where(conversation_id: conversations.pluck(:id))
  end

  def push_event_data
    {
      id: id,
      name: name
    }
  end

  private

  def record_communication_thread_nullifications
    return if account_teardown?

    # Fence new team memberships before scanning Conversations. An in-flight
    # join holds a FK key-share lock until it commits, so this waits for it;
    # later joins cannot reach the Thread resolver before deletion completes.
    self.class.where(id: id).lock('FOR UPDATE').pick(:id)
    # Status callbacks hold Conversation before Thread. Lock the complete
    # membership that dependent: :nullify will update before writing facts.
    conversations.select(:id).order(:id).lock.load
    source_event_id = SecureRandom.uuid
    occurred_at = Time.current
    communication_threads.find_each do |thread|
      CommunicationThreads::StateTransitionWriter.new(
        thread: thread,
        attributes: { team_id: nil },
        actor: Current.executed_by || Current.user,
        source: 'team_deleted',
        source_record: self,
        source_event_id: source_event_id,
        occurred_at: occurred_at
      ).perform
    end
  end

  def account_teardown?
    self.class.connection.select_value("SELECT current_setting('onelink.account_teardown_id', true)") == account_id.to_s
  end
end

Team.include_mod_with('Audit::Team')
