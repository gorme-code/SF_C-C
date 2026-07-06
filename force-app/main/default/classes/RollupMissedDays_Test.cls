@isTest
private class RollupMissedDays_Test {

    @testSetup
    static void setup() {
        Id districtRt = Account.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('District').getRecordTypeId();
        Id schoolRt = Account.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('School').getRecordTypeId();

        Account dist = new Account(Name = 'Rollup District', RecordTypeId = districtRt);
        insert dist;
        insert new List<Account>{
            new Account(Name = 'Rollup School A', ParentId = dist.Id, RecordTypeId = schoolRt),
            new Account(Name = 'Rollup School B', ParentId = dist.Id, RecordTypeId = schoolRt),
            new Account(Name = 'Rollup School C', ParentId = dist.Id, RecordTypeId = schoolRt)
        };
    }

    @isTest
    static void testRollup() {
        Account a = [SELECT Id FROM Account WHERE Name = 'Rollup School A' LIMIT 1];
        Account b = [SELECT Id FROM Account WHERE Name = 'Rollup School B' LIMIT 1];

        // Dates in February of the current school year so School_Year__c == the rollup's "current year"
        Date today = Date.today();
        Integer sy = (today.month() >= 7) ? today.year() + 1 : today.year();

        List<Closure_Event__c> evs = new List<Closure_Event__c>{
            new Closure_Event__c(School__c = a.Id, Closure_Date__c = Date.newInstance(sy, 2, 1),
                Instructional_Day__c = true, Hours_Missed__c = 6.5, Closure_Reason__c = 'Weather_Snow', Status__c = 'Submitted'),
            new Closure_Event__c(School__c = a.Id, Closure_Date__c = Date.newInstance(sy, 2, 2),
                Instructional_Day__c = true, Hours_Missed__c = 6.5, Closure_Reason__c = 'Weather_Snow', Status__c = 'Submitted'),
            new Closure_Event__c(School__c = a.Id, Closure_Date__c = Date.newInstance(sy, 2, 3),
                Instructional_Day__c = true, Hours_Missed__c = 6.5, Closure_Reason__c = 'Weather_Snow', Status__c = 'Submitted'),
            new Closure_Event__c(School__c = b.Id, Closure_Date__c = Date.newInstance(sy, 2, 1),
                Instructional_Day__c = true, Hours_Missed__c = 6.5, Closure_Reason__c = 'Weather_Snow', Status__c = 'Submitted')
        };
        insert evs;

        Test.startTest();
        RollupMissedDays.rollup();
        Test.stopTest();

        Map<String, Decimal> daysByName = new Map<String, Decimal>();
        for (Account acc : [SELECT Name, Total_Missed_Days_YTD__c FROM Account WHERE Name LIKE 'Rollup %']) {
            daysByName.put(acc.Name, acc.Total_Missed_Days_YTD__c);
        }

        System.assert(daysByName.get('Rollup School A') == 3,
            'School A: 3 missed days, got ' + daysByName.get('Rollup School A'));
        System.assert(daysByName.get('Rollup School B') == 1,
            'School B: 1 missed day, got ' + daysByName.get('Rollup School B'));
        System.assert(daysByName.get('Rollup School C') == 0,
            'School C: 0 (no closures), got ' + daysByName.get('Rollup School C'));
        System.assert(daysByName.get('Rollup District') == 4,
            'District: sum of children = 4, got ' + daysByName.get('Rollup District'));
    }
}