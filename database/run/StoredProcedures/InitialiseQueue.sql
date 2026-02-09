

CREATE procedure [run].[InitialiseQueue] (@LoadID UNIQUEIDENTIFIER)
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
                              [NotebookRunURL]
            )
      select DISTINCT @LoadID
                  ,NULL ParentQueueID
                  ,NULL ADFExecutionID
                  ,p.ProcessID
                  ,p.ProcessName
                  ,p.ProcessType
                  ,p.ProcessSubType
                  ,p.ProcessTarget
                  ,p.Contract
                  ,p.Config
                  ,p.NotebookName
                  ,getdate()
                  ,null
                  ,null
                  ,l.PartitionDate
                  ,'PENDING'
                  ,'extract path'
                  ,null
                  ,null
      from run.Load l
      join run.LoadProcessGroup pg on pg.LoadID=l.LoadID
      join Config.vProcess p on p.ProcessGroupID=pg.ProcessGroupID
      join Config.ProcessDAG dag on dag.ProcessID=p.ProcessID
      where pg.LoadID=@LoadID
      and p.Active=1
      and pg.Active=1
      and dag.DependentOnProcessID is null
END
GO

