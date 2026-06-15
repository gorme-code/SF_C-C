// Manually run the submission expansion for a specific Case (same logic the
// Create_Closure_Events flow invokes). Use when a Case was created in a context
// where the record-triggered flow did not fire (e.g. manual Quick Action entry).
ExpandClosureSubmission.Request r = new ExpandClosureSubmission.Request();
r.caseId = '500Va00000OCbcHIAT'; // Case 00009454
ExpandClosureSubmission.run(new List<ExpandClosureSubmission.Request>{ r });
System.debug('Expansion invoked for case 500Va00000OCbcHIAT');
