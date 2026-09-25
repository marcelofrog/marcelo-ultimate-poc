package curation.policies

import rego.v1

app_version := input.data.applications.getApplicationVersion

application_evidence := [predicate |
	predicate := app_version.application.evidenceSubject.evidenceConnection.edges[_].node
]

version_evidence := [predicate | predicate := app_version.evidenceSubject.evidenceConnection.edges[_].node]

all_layers_evidences := array.concat(application_evidence, version_evidence)

required_predicate_type := input.params.predicateType

required_count := to_number(input.params.approver_count_required)

change_control_evidence := [e |
	some e in all_layers_evidences
	e.predicateType == required_predicate_type
]

approver_list_from(pred) := pred.approver_list if {
	is_object(pred)
}

approver_list_from(pred) := json.unmarshal(pred).approver_list if {
	is_string(pred)
}

approver_counts := [n |
	some e in change_control_evidence
	list := approver_list_from(e.predicate)
	n := count(list)
]

best_count := max(array.concat(approver_counts, [0]))

default meets_required := false

meets_required if {
	count(change_control_evidence) > 0
	best_count >= required_count
}

message := sprintf("no application evidence with predicateType %s", [required_predicate_type]) if {
	count(change_control_evidence) == 0
}

message := sprintf("found %d approver(s), need at least %d", [best_count, required_count]) if {
	count(change_control_evidence) > 0
	not meets_required
}

message := sprintf("found %d approver(s), required %d", [best_count, required_count]) if {
	meets_required
}

allow := {
	"should_allow": meets_required,
	"message": message,
}
