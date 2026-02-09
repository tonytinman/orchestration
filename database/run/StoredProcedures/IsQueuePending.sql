create procedure [run].[IsQueuePending] @LoadID UNIQUEIDENTIFIER
as
select case when count([QueueID]) > 0 then 1 else 0 end [IsPending]
from run.ProcessQueue
where
LoadID=@LoadID
and ProcessStatus = 'PENDING'
GO
