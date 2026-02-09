




CREATE procedure [run].[AddDependenciesToQueue] (@QueueID int)
AS
BEGIN
      INSERT INTO [run].[ProcessQueue]
                     (  [LoadID],
                              [ParentQueueID],
                              [ADFExecutionID],
                              [ProcessID],
                              [ProcessName],
                              [ProcessType],
                              [ProcessSubType],
                            [ProcessTarget],
                              [Contract],
                              [Config],
                              [NotebookName],
                              [ProcessCreateDate],
                              [ProcessStartDate],
                              [ProcessEndDate],
                              [ProcessPartition],
                              [ProcessStatus],
                              [ExtractPath],
                              [InitiatingProcessID],
                              [NotebookRunURL],
                                [TriggerQueueID]
            )
      select distinct 
                l.LoadID
                  ,NULL ParentQueueID
                  ,NULL ADFExecutionID
                  ,p.ProcessID
                  ,p.ProcessName
                  ,p.ProcessType
                  ,p.ProcessSubType
                ,COALESCE(p.ProcessTarget,'')
                  ,p.Contract
                  ,p.Config
                  ,p.NotebookName
                  ,getdate() [ProcessCreateDate]
                  ,null [ProcessStartDate]
                  ,null [ProcessEndDate]
                  ,l.PartitionDate
                  ,'PENDING' [ProcessStatus]
                  ,'extract path' [ExtractPath]
                  ,null [InitiatingProcessID]
                  ,null [NotebookRunURL]
,@QueueID
      from run.ProcessQueue q
      join Config.ProcessDAG dag on dag.DependentOnProcessID=q.ProcessID
      join Config.vProcess p on p.ProcessID = dag.ProcessID
      join run.LoadProcessGroup pg on pg.ProcessGroupID=p.ProcessGroupID
      join run.Load l on l.LoadID = pg.LoadID
      where q.QueueID=@QueueID and pg.Active=1 and p.Active=1 and l.LoadID=q.LoadID

      --ensure process doesn;t already exist in the queue
      and not exists (select 1 from run.ProcessQueue q1 where q1.ProcessId = p.ProcessId and q1.LoadID=q.LoadID)

END
GO

