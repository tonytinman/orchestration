


CREATE PROCEDURE [run].[InitiateParentLoad] (@LoadID uniqueidentifier
                                                                        ,@ADFExecution varchar(500)
                                                                        ,@ProcessGroup varchar(100) = null)
                                                                        
AS
BEGIN

DECLARE @ParentQueueID INT = 0
DECLARE @EntitiesToProcess INT = 0


SELECT @EntitiesToProcess=count(QueueID)
FROM run.ProcessQueue Q
WHERE Q.ProcessStatus = 'PENDING'
AND Q.ParentQueueID IS NULL
AND Q.LoadID=@LoadID

--if there are items to process create a parent record and update the queued items
IF (@EntitiesToProcess > 0)
BEGIN
      --CREATE A NEW PARENT PROCESS RECORD
    INSERT INTO run.ProcessQueue
    ([LoadID]
        ,[ProcessID]
        ,[ProcessName]
        ,[ProcessType]
        ,[ProcessSubType]
        ,[ProcessCreateDate]
        ,[ProcessStartDate]
        ,[ProcessStatus])
    SELECT
          @LoadID  [LoadID]
        ,0 [ProcessID]
        ,'Parent'[ProcessName]
        ,'Parent'[ProcessType]
        ,'Parent'[ProcessSubType]
        ,getdate()[ProcessCreateDate]
        ,getdate()[ProcessStartDate]
        ,'IN PROGRESS'[ProcessStatus]

    SET @ParentQueueID = @@IDENTITY


      --UPDATE CURRENTLY ORPHANED PROCESS QUEUE RECORDS FOR THE SPECIFIED PROCESS GROUP AND LOAD ID
    UPDATE Q
    SET ParentQueueID = @ParentQueueID
    FROM run.ProcessQueue Q
    WHERE Q.ProcessStatus = 'PENDING'
      AND Q.ParentQueueID IS NULL
      AND Q.LoadID=@LoadID

      SET @EntitiesToProcess=@@ROWCOUNT
END
    SELECT @ParentQueueID ParentQueueID, @EntitiesToProcess as EntitiesToProcess
END
GO

