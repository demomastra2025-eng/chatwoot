class SuperAdmin::CaptainObservabilityController < SuperAdmin::ApplicationController
  def show
    @fleet_report = Llm::Monitoring::FleetSnapshot.new.call
  end
end
