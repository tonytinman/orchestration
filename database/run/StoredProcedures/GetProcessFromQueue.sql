CREATE PROCEDURE [run].[GetProcessFromQueue] @QueueID int
AS
BEGIN
      SELECT
            [ProcessID]
            ,[ProcessName]
            ,[ProcessType]
            ,[ProcessSubType]
            ,[Contract]
            ,[Config]
            ,[NotebookName]
      FROM  [run].[ProcessQueue]
END
GO
