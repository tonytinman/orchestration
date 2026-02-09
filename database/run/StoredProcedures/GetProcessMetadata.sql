
CREATE  procedure [run].[GetProcessMetadata] (@LoadID NVARCHAR(MAX), @QueueID int)
AS
 BEGIN

    SELECT 
        ProcessID,
        ProcessName,
        ProcessType,
        ProcessSubType,
        Contract as ProcessContract,   
        Config as ProcessConfig,     
        NotebookName as ScriptName,
        TriggerQueueID
    FROM  run.ProcessQueue 
    WHERE QueueID = @QueueID
    AND CONVERT(NVARCHAR(MAX),LoadID) =  @LoadID;

END
GO

