module AccessControl::ModeControlled
  extend ActiveSupport::Concern

  MODES = {
    legacy: 'legacy',
    shadow: 'shadow',
    enforced: 'enforced'
  }.freeze

  included do
    enum :access_control_mode, MODES, prefix: true
    validate :access_control_mode_changed_through_transition
  end

  def authorize_access_control_mode_transition
    @access_control_mode_transition_authorized = true
    yield
  ensure
    @access_control_mode_transition_authorized = false
  end

  private

  def access_control_mode_changed_through_transition
    return unless will_save_change_to_access_control_mode?
    return if new_record? && access_control_mode_legacy?
    return if @access_control_mode_transition_authorized

    errors.add(:access_control_mode, 'must be changed through AccessControl::ModeTransition')
  end
end
