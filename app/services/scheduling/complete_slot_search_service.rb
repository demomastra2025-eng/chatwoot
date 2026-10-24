# The slot search with every free start of the range, never cut at a count. The answer for the patient agent groups the starts by
# specialist and day (Captain::Tools::Agent::SlotsPayload), so a cut at a count would drop the end of a day or the days after the
# first: with the cap of 100 starts, one specialist's answer ended about eight hours into the first day.
#
# AvailableSlotSearchService cuts in three places: the sorted list of all specialists, the list of each MedElement specialist, and
# (through the limit it passes on) the local-rules query, which caps again at its own 50 unless told not to. This class lifts the
# three without touching that service, by overriding the two private methods that set them. When the service itself grows an option
# for it, this class is to become that option.
class Scheduling::CompleteSlotSearchService < Scheduling::AvailableSlotSearchService
  # A count the range cannot reach: 31 days of 5-minute starts of 100 specialists is about 900_000.
  NO_LIMIT = 10_000_000

  private

  def normalize_limit(_value)
    NO_LIMIT
  end

  def local_slots(resource, **)
    super(resource, **, uncapped: true)
  end
end
