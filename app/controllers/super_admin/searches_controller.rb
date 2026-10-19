# frozen_string_literal: true

# The results of the search box in the header of the super admin (SuperAdmin::GlobalSearch): accounts, users and
# organizations in one page, ten of each with a link to the filtered list. Only a signed-in super admin reaches it
# (SuperAdmin::ApplicationController).
class SuperAdmin::SearchesController < SuperAdmin::ApplicationController
  def show
    @result = SuperAdmin::GlobalSearch.new(params[:q].is_a?(String) ? params[:q] : '').call
  end
end
