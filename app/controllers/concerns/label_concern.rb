module LabelConcern
  def create
    update_label_list(permitted_params[:labels])
    @labels = current_label_list
  end

  def index
    @labels = current_label_list
  end

  private

  def update_label_list(labels)
    model.update_labels(labels)
  end

  def current_label_list
    model.label_list
  end
end
