
CREATE  procedure [run].[GetProcessConfig_ExtractADFAzureBlob] (@LoadID UNIQUEIDENTIFIER, @QueueID int)
AS
BEGIN
    SELECT TOP 1
        cp.ProcessID,
        cp.Classification,        
        JSON_VALUE(cp.Config,'$.TYPE') as ConfigType,
        JSON_VALUE(cp.Config,'$.SOURCE') as ConfigSource,
        JSON_VALUE(cp.Config,'$.SOURCE_CONNECTION.TYPE') as ConfigSource_ConnectionType,
        JSON_VALUE(cp.Config,'$.SOURCE_CONNECTION.CONNECTIONSTRING.CONTAINER') as ConfigSource_SorageContainer,
        JSON_VALUE(cp.Config,'$.SOURCE_CONNECTION.CONNECTIONSTRING.STORAGEACCOUNTNAME') as ConfigSource_StorageName,
        JSON_VALUE(cp.Config,'$.SOURCE_CONNECTION.CONNECTIONSTRING.DIRECTORY') as ConfigSource_Directory,
        JSON_VALUE(cp.Config,'$.DEST_CONNECTION.TYPE') as ConfigDest_Con_Type,
        JSON_VALUE(cp.Config,'$.DEST_CONNECTION.CONNECTIONSTRING.CONTAINER') as ConfigDest_SorageContainer,
        JSON_VALUE(cp.Config,'$.DEST_CONNECTION.CONNECTIONSTRING.STORAGEACCOUNTNAME') as ConfigDest_StorageName,
        JSON_VALUE(cp.Config,'$.DEST_CONNECTION.CONNECTIONSTRING.DIRECTORY') as ConfigDest_Directory,
        JSON_VALUE(cp.Config,'$.OBJECT.NAME') as ConfigObject_Name,
        JSON_VALUE(cp.Config,'$.OBJECT.PATH') as ConfigObject_Path
    FROM  run.ProcessQueue pq
    JOIN config.Process cp
    ON cp.ProcessID=pq.ProcessID 
    WHERE ISJSON(cp.Config)=1
    AND pq.QueueID = @QueueID
    AND pq.LoadID = @LoadID;
END
GO

