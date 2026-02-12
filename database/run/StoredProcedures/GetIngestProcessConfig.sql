
CREATE proc [run].[GetIngestProcessConfig] @QueueID INT
as
SELECT
    q1.QueueID,
    pg.ProcessGroupName,
    q1.NotebookName,
    q1.Contract,
    q1.ProcessStartDate LoadDate,
    CASE
        WHEN q1.ProcessType = 'TRANSFORM' THEN '{"source_ref":" "}'
        ELSE q2.ProcessAuditData
    END AS ProcessAuditData
	,
	ac.cluster_id AS cluster_id,
	q1.ProcessSubType
FROM run.ProcessQueue AS q1
LEFT JOIN run.ProcessQueue AS q2
    ON q2.QueueID = q1.TriggerQueueID
LEFT JOIN config.Process AS p
    ON p.ProcessID = q1.ProcessID
LEFT JOIN config.ProcessGroup AS pg
    ON pg.ProcessGroupID = p.ProcessGroupID
LEFT JOIN config.ADBCluster AS ac
   ON ac.ProcessGroupName = pg.ProcessGroupName
WHERE q1.QueueID = @QueueID;
GO

