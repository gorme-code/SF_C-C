/**
 * Invoked nightly by the Calculate_YTD_Missed_Days scheduled flow.
 * Recomputes Account.Total_Missed_Days_YTD__c for School and District accounts
 * for the current school year, using a single aggregate query (no SOQL-in-loop).
 *
 * NOTE: single-transaction rollup. Fine for SC volumes (~80 districts / ~1,200
 * schools). If the school count ever approaches governor limits, convert to
 * Batch Apex.
 */
public with sharing class RollupMissedDays {

    @InvocableMethod(label='Roll Up YTD Missed Days' description='Recomputes Total_Missed_Days_YTD__c on School and District accounts for the current school year.')
    public static void run(List<String> ignored) {
        rollup();
    }

    public static void rollup() {
        // Current school year — matches Closure_Event__c.School_Year__c (month >= 7 -> year + 1)
        Date today = Date.today();
        Integer yr = today.year();
        String schoolYear = (today.month() >= 7) ? String.valueOf(yr + 1) : String.valueOf(yr);

        Compliance_Rules__mdt rules = Compliance_Rules__mdt.getInstance('Default');
        Decimal hoursPerDay = (rules != null
                && rules.Hours_Per_Instructional_Day__c != null
                && rules.Hours_Per_Instructional_Day__c != 0)
            ? rules.Hours_Per_Instructional_Day__c
            : 6.5;

        // One aggregate query: missed instructional hours per school this year
        Map<Id, Decimal> daysBySchool = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT School__c sid, SUM(Hours_Missed__c) totalHours
            FROM Closure_Event__c
            WHERE School_Year__c = :schoolYear AND Instructional_Day__c = true
            GROUP BY School__c
        ]) {
            Id sid = (Id) ar.get('sid');
            if (sid == null) {
                continue;
            }
            Decimal totalHours = (Decimal) ar.get('totalHours');
            daysBySchool.put(sid, (totalHours == null ? 0 : totalHours) / hoursPerDay);
        }

        // Update every School account (0 when it had no qualifying closures)
        List<Account> schoolUpdates = new List<Account>();
        Map<Id, Decimal> daysByDistrict = new Map<Id, Decimal>();
        for (Account s : [
            SELECT Id, ParentId, Total_Missed_Days_YTD__c
            FROM Account
            WHERE RecordType.DeveloperName = 'School'
        ]) {
            Decimal d = daysBySchool.containsKey(s.Id) ? daysBySchool.get(s.Id) : 0;
            s.Total_Missed_Days_YTD__c = d;
            schoolUpdates.add(s);
            if (s.ParentId != null) {
                Decimal running = daysByDistrict.containsKey(s.ParentId) ? daysByDistrict.get(s.ParentId) : 0;
                daysByDistrict.put(s.ParentId, running + d);
            }
        }
        if (!schoolUpdates.isEmpty()) {
            update schoolUpdates;
        }

        // Update every District account by summing its child schools
        List<Account> districtUpdates = new List<Account>();
        for (Account dist : [
            SELECT Id, Total_Missed_Days_YTD__c
            FROM Account
            WHERE RecordType.DeveloperName = 'District'
        ]) {
            dist.Total_Missed_Days_YTD__c = daysByDistrict.containsKey(dist.Id) ? daysByDistrict.get(dist.Id) : 0;
            districtUpdates.add(dist);
        }
        if (!districtUpdates.isEmpty()) {
            update districtUpdates;
        }
    }
}