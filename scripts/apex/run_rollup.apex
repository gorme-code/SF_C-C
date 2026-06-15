// Manually invoke the nightly YTD rollup (same logic the Calculate_YTD_Missed_Days
// scheduled flow runs). Recomputes Account.Total_Missed_Days_YTD__c for School and
// District accounts for the current school year.
RollupMissedDays.rollup();
System.debug('Rollup complete.');
