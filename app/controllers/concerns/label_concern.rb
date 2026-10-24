# Shared by the conversation and the contact label endpoints. A change is sent as add / remove (what the dashboard does);
# a whole list is still accepted from older clients and is read as a change against what that client could see, see
# Labels::UnifiedAssignmentService.delta_from_params. The controller says what that is (visible_labels), how to write
# (change_labels) and what to answer with (current_label_list).
module LabelConcern
  def create
    add, remove = Labels::UnifiedAssignmentService.delta_from_params(permitted_params, visible_labels: visible_labels)
    change_labels(add: add, remove: remove)
    @labels = current_label_list
  end

  def index
    @labels = current_label_list
  end
end
