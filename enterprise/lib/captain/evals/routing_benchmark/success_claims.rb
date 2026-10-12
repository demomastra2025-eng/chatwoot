# frozen_string_literal: true

# The detector moved to the runtime: the council composer validates its drafts with it, and the benchmark scorer
# keeps using it through this name. See Captain::Runtime::SuccessClaims for what counts as a claim.
Captain::Evals::RoutingBenchmark::SuccessClaims = Captain::Runtime::SuccessClaims
