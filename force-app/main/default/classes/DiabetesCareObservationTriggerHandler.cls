/**
 * @description Trigger Handler for CareObservation records to create follow-up Tasks for elevated HbA1c.
 * - Bulkified: no SOQL/DML in loops
 * - Uses custom metadata thresholds (Target/Warning/Critical)
 * - Creates Tasks in user mode and sets required fields
 * - Idempotent for recent duplicates (30 days window)
 * @author Agentforce
 */
public with sharing class DiabetesCareObservationTriggerHandler {

    /**
     * Handle after-insert for CareObservation.
     */
    public static void handleAfterInsert(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }

    /**
     * Handle after-update for CareObservation.
     */
    public static void handleAfterUpdate(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }

    /**
     * Core processing logic. Creates follow-up Tasks for finalized HbA1c observations
     * meeting or exceeding Warning/Critical thresholds.
     */
    private static void processObservations(List<CareObservation> newObservations) {
        if (newObservations == null || newObservations.isEmpty()) {
            return; // Return Early
        }

        // Get thresholds from Custom Metadata (cached automatically)
        Diabetes_Threshold__mdt thresholds = [
            SELECT Target_Percentage__c, Warning_Percentage__c, Critical_Percentage__c
            FROM Diabetes_Threshold__mdt
            WHERE DeveloperName = 'Standard_Diabetes_Thresholds'
            LIMIT 1
        ];

        // Collections for bulk processing
        Set<Id> codeIds = new Set<Id>();
        Map<Id, Decimal> observationHbA1cMap = new Map<Id, Decimal>();
        Map<Id, Id> observationToCodeId = new Map<Id, Id>();

        // First pass: gather CodeIds and capture numeric values for candidate observations
        for (CareObservation obs : newObservations) {
            if (obs == null) continue;
            if (obs.CodeId != null) {
                codeIds.add(obs.CodeId);
                observationToCodeId.put(obs.Id, obs.CodeId);
            }
        }

        // Guard if no codes present at all
        if (codeIds.isEmpty()) {
            return; // nothing to process
        }

        // Query CodeSet records to get code names
        Map<Id, CodeSet> codeMap = new Map<Id, CodeSet>(
            [SELECT Id, Name FROM CodeSet WHERE Id IN :codeIds]
        );

        // Second pass: decide which observations are relevant HbA1c and above warning threshold
        Set<Id> candidateObservationIds = new Set<Id>();
        for (CareObservation obs : newObservations) {
            if (obs == null) continue;

            CodeSet code = codeMap.get(observationToCodeId.get(obs.Id));
            String codeName = (code != null) ? code.Name : null;

            // Only process finalized HbA1c observations with valid numeric data and subject
            if (codeName == 'HbA1c'
                && obs.ObservationStatus == 'final'
                && obs.ObservedValueType == 'Quantity'
                && obs.ObservedValueNumerator != null
                && obs.ObservedSubjectId != null
                && obs.ObservedValueNumerator >= thresholds.Warning_Percentage__c) {

                candidateObservationIds.add(obs.Id);
                observationHbA1cMap.put(obs.Id, obs.ObservedValueNumerator);
            }
        }

        if (candidateObservationIds.isEmpty()) {
            return; // nothing to do
        }

        // Bulk query for any existing follow-up Tasks on these observations in the last 30 days
        Map<Id, Boolean> observationHasRecentTask = new Map<Id, Boolean>();
        for (Id oid : candidateObservationIds) observationHasRecentTask.put(oid, false);

        for (Task t : [
            SELECT Id, WhatId, Subject, Status, CreatedDate
            FROM Task
            WHERE WhatId IN :candidateObservationIds
              AND Subject LIKE '%HbA1c Follow-up%'
              AND Status != 'Completed'
              AND CreatedDate = LAST_N_DAYS:30
        ]) {
            observationHasRecentTask.put(t.WhatId, true);
        }

        // Build tasks to insert
        List<Task> tasksToInsert = new List<Task>();

        for (Id observationId : candidateObservationIds) {
            if (observationHasRecentTask.get(observationId) == true) {
                continue; // skip duplicates in the time window
            }

            Decimal hba1cValue = observationHbA1cMap.get(observationId);

            Task followUpTask = new Task();
            followUpTask.Subject = 'HbA1c Follow-up Required - ' + Date.today().format();
            followUpTask.WhatId = observationId; // Link to CareObservation
            // Required field
            followUpTask.ActivityDate = Date.today(); // Bug 2 fix

            // Priority based on thresholds
            if (hba1cValue != null && hba1cValue >= thresholds.Critical_Percentage__c) {
                followUpTask.Priority = 'High';
                // Optional: tighter due date for critical; keep ActivityDate as today
            } else if (hba1cValue != null && hba1cValue >= thresholds.Warning_Percentage__c) {
                followUpTask.Priority = 'Normal';
            } else {
                followUpTask.Priority = 'Low';
            }

            followUpTask.Status = 'Not Started';
            followUpTask.Type = 'Call';

            // Safe description with null checks (Bug 3 fix)
            String hba1cText = (hba1cValue == null) ? 'N/A' : String.valueOf(hba1cValue.setScale(2));
            followUpTask.Description =
                'Patient has new HbA1c level of ' + hba1cText + '%. Schedule follow-up appointment to review ' +
                'diabetes management plan and medication adherence. ' +
                'Thresholds: Target <' + String.valueOf(thresholds.Target_Percentage__c) +
                '%, Warning ≥' + String.valueOf(thresholds.Warning_Percentage__c) +
                '%, Critical ≥' + String.valueOf(thresholds.Critical_Percentage__c) + '%.';

            tasksToInsert.add(followUpTask);
        }

        if (!tasksToInsert.isEmpty()) {
            // Bulk DML (Bug 4 fix) in USER_MODE per security rules
            Database.SaveResult[] results = Database.insert(tasksToInsert, /*allOrNone*/ false, AccessLevel.USER_MODE);
            // Optional: collect and surface errors via platform events or custom logging if required
            // for this exercise we won't throw to avoid breaking the transaction on partial failures
        }
    }
}