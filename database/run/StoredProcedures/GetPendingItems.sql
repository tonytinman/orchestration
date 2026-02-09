/*
Purpose: This procedure return pending queue items from Porcess Queue for specified load.
Parameter: Load Id
Code: 
    Get Non-Depedent queue records.
    Get Dependent Queue Item records
    Return dataset combining above two.
*/
CREATE procedure [run].[GetPendingItems] (@LoadID uniqueidentifier)
as
begin

/*
Query giving wrong resultset data ******************************************
with dependencies as (
select q1.queueid
            ,q1.loadid
            ,q1.ProcessID
            ,dag.DependsOnProcessID
            ,case when (q2.QueueID is not null) or (dag.DependsOnProcessID is null) then 1 else 0 end [dependency_status]
from  run.processqueue q1
join  config.vProcessDAG dag on dag.ProcessID = q1.processid
left join run.processqueue q2 on q2.LoadID = @LoadID
                                                and
                                                q2.ProcessID = dag.DependsOnProcessID
                                                and
                                                q2.ProcessStatus = dag.DependencyType
where q1.LoadID = @LoadID
            and q1.ProcessStatus = 'PENDING'
),
can_process as (
select q.processid
from dependencies d
join run.processqueue q on q.queueid=d.queueid and q.LoadID=d.LoadID
group by q.ProcessID
having min(cast(d.dependency_status as int)) = 1
)
select q.*
from can_process p
join run.processqueue q on q.processid=p.processid
*/

SELECT LoadID,ProcessID,QueueID,ParentQueueID,ADFExecutionID,ProcessType,ProcessSubType,ProcessTarget,
[Contract],Config,NotebookName,NotebookRunURL,ProcessPartition,ProcessStatus,ExtractPath,TriggerQueueID
FROM
(

    SELECT DISTINCT base.QueueID,base.LoadID,base.ProcessID,base.ParentQueueID,base.ADFExecutionID,base.ProcessType,base.ProcessSubType,base.ProcessTarget,
    base.Contract,base.Config,base.NotebookName,base.NotebookRunURL,base.ProcessPartition,base.ProcessStatus,base.ExtractPath,base.TriggerQueueID    
    FROM run.processqueue  as base
    JOIN config.ProcessDAG as map ON map.processid=base.processid
    JOIN run.processqueue  as dpn ON dpn.ProcessID=map.DependentOnProcessID AND dpn.ProcessStatus=map.DependencyType
    WHERE base.LoadID=@LoadID
    AND dpn.LoadID=@LoadID
    AND base.ProcessStatus='PENDING'

    UNION ALL
    SELECT base.QueueID,base.LoadID,base.ProcessID,base.ParentQueueID,base.ADFExecutionID,base.ProcessType,base.ProcessSubType,base.ProcessTarget,
    base.Contract,base.Config,base.NotebookName,base.NotebookRunURL,base.ProcessPartition,base.ProcessStatus,base.ExtractPath,base.TriggerQueueID
    FROM run.processqueue  as base
    LEFT JOIN config.ProcessDAG as map ON map.processid=base.processid
    WHERE map.DependentOnProcessID IS NULL
    AND base.LoadID=@LoadID
    AND base.ProcessStatus='PENDING'
) INQ
ORDER BY QueueID

end
GO

