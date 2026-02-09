create proc [run].[GetProcessConfig_Ingest] @QueueID INT
as
select q1.QueueID
        ,q1.NotebookName
        ,q1.Contract
        ,q2.ExtractPath
from run.ProcessQueue q1 
left join run.ProcessQueue q2 on q2.QueueID = q1.TriggerQueueID
where q1.QueueID = @QueueID
GO
