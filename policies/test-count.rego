# -----------------------------------------------------------------------------
# test-count.rego
#
# AppTrust promotion gate policy. Blocks promotion of an application version
# unless a "test-results" evidence predicate is attached to the version and
# reports at least `data.parameters.min_passing_tests` successful tests.
#
# Input shape passed by the AppTrust gate engine:
#   input.application.key       string
#   input.application.version   string
#   input.evidence              []{ predicateType, predicate, ... }
#   input.parameters            { min_passing_tests: int }
#
# The build workflow publishes evidence like:
#   {
#     "predicateType": "https://jfrog.com/evidence/test-results/v1",
#     "predicate": {
#       "framework": "pytest",
#       "passed": 12,
#       "failed": 0,
#       "skipped": 0
#     }
#   }
# -----------------------------------------------------------------------------
package apptrust.gates.testcount

import future.keywords.if
import future.keywords.in

default allow := false

min_required := input.parameters.min_passing_tests

test_evidence[e] {
    some i
    e := input.evidence[i]
    e.predicateType == "https://jfrog.com/evidence/test-results/v1"
}

passing_total := n {
    n := sum([e.predicate.passed | e := test_evidence[_]])
}

allow if {
    count(test_evidence) > 0
    passing_total >= min_required
    all_zero_failures
}

all_zero_failures if {
    every e in test_evidence {
        e.predicate.failed == 0
    }
}

# The gate engine reads `deny` as an array of human-readable strings.
deny[msg] {
    count(test_evidence) == 0
    msg := "no test-results evidence attached to this application version"
}

deny[msg] {
    count(test_evidence) > 0
    passing_total < min_required
    msg := sprintf("only %d passing tests, need at least %d", [passing_total, min_required])
}

deny[msg] {
    some e in test_evidence
    e.predicate.failed > 0
    msg := sprintf("evidence reports %d failing tests", [e.predicate.failed])
}
