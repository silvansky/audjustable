/**********************************************************************************
 AudioPlayer.m
 
 Created by Thong Nguyen on 14/05/2012.
 http://http://code.google.com/p/bluecucumber
 
 Inspired by Matt Gallagher's AudioStreamer:
 https://github.com/mattgallagher/AudioStreamer 
 
 Copyright (c) 2012 Thong Nguyen (tumtumtum@gmail.com). All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 1. Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 2. Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 3. All advertising materials mentioning features or use of this software
 must display the following acknowledgement:
 This product includes software developed by the <organization>.
 4. Neither the name of the <organization> nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
**********************************************************************************/

#import "AudioPlayer.h"
#import "AudioToolbox/AudioToolbox.h"
#import "HttpDataSource.h"
#import "LocalFileDataSource.h"
#import "libkern/OSAtomic.h"

#define BitRateEstimationMinPackets (64)
#define AudioPlayerBuffersNeededToStart (16)
#define AudioPlayerDefaultReadBufferSize (4 * 1024)
#define AudioPlayerDefaultPacketBufferSize (1024)

@interface NSMutableArray(AudioPlayerExtensions)
-(void) enqueue:(id)obj;
-(id) dequeue;
-(id) peek;
@end

@implementation NSMutableArray(AudioPlayerExtensions)

-(void) enqueue:(id)obj
{
    [self insertObject:obj atIndex:0];
}

-(void) skipQueue:(id)obj
{
    [self addObject:obj];
}

-(id) dequeue
{
    if ([self count] == 0)
    {
        return nil;
    }
    
    id retval = [self lastObject];
    
    [self removeLastObject];
    
    return retval;
}

-(id) peek
{
    return [self lastObject];
}

-(id) peekRecent
{
    if (self.count == 0)
    {
        return nil;
    }
    
    return [self objectAtIndex:0];
}

@end

@interface QueueEntry : NSObject
{
@public
    BOOL parsedHeader;
    double sampleRate;
    double lastProgress;
    double packetDuration;
    UInt64 audioDataOffset;
    UInt64 audioDataByteCount;
    UInt32 packetBufferSize;
    volatile double seekTime;
    volatile int bytesPlayed;
    volatile int processedPacketsCount;
	volatile int processedPacketsSizeTotal;
    AudioStreamBasicDescription audioStreamBasicDescription;
}
@property (readwrite, retain) NSObject* queueItemId;
@property (readwrite, retain) DataSource* dataSource;
@property (readwrite) int bufferIndex;
@property (readonly) UInt64 audioDataLengthInBytes;

-(double) duration;
-(double) calculatedBitRate;
-(double) progress;

-(id) initWithDataSource:(DataSource*)dataSource andQueueItemId:(NSObject*)queueItemId;
-(id) initWithDataSource:(DataSource*)dataSource andQueueItemId:(NSObject*)queueItemId andBufferIndex:(int)bufferIndex;

@end

@implementation QueueEntry
@synthesize dataSource, queueItemId, bufferIndex;

-(id) initWithDataSource:(DataSource*)dataSourceIn andQueueItemId:(NSObject*)queueItemIdIn
{
    return [self initWithDataSource:dataSourceIn andQueueItemId:queueItemIdIn andBufferIndex:-1];
}

-(id) initWithDataSource:(DataSource*)dataSourceIn andQueueItemId:(NSObject*)queueItemIdIn andBufferIndex:(int)bufferIndexIn
{
    if (self = [super init])
    {
        self.dataSource = dataSourceIn;
        self.queueItemId = queueItemIdIn;
        self.bufferIndex = bufferIndexIn;
    }
    
    return self;
}

-(double) calculatedBitRate
{
    double retval;
    
    if (packetDuration && processedPacketsCount > BitRateEstimationMinPackets)
	{
		double averagePacketByteSize = processedPacketsSizeTotal / processedPacketsCount;
        
		retval = averagePacketByteSize / packetDuration * 8;
        
        return retval;
	}
	
    retval = (audioStreamBasicDescription.mBytesPerFrame * audioStreamBasicDescription.mSampleRate) * 8;
    
    return retval;
}

-(double) progress
{
    double retval = lastProgress;
    double duration = [self duration];
    
    if (self->sampleRate > 0)
    {
        double calculatedBitrate = [self calculatedBitRate];
        
        retval = self->bytesPlayed / calculatedBitrate * 8;
        
        retval = seekTime + retval;
    }
    
    if (retval > duration)
    {
        retval = duration;
    }
	
	return retval;
}

-(double) duration
{
    if (self->sampleRate <= 0)
    {
        return 0;
    }
    
    UInt64 audioDataLengthInBytes = [self audioDataLengthInBytes];
    
    double calculatedBitRate = [self calculatedBitRate];
    
    if (calculatedBitRate == 0 || self->dataSource.length == 0)
    {
        return 0;
    }
    
    return audioDataLengthInBytes / (calculatedBitRate / 8);
}

-(UInt64) audioDataLengthInBytes
{
    if (audioDataByteCount)
    {
        return audioDataByteCount;
    }
    else
    {
        if (!dataSource.length)
        {
            return 0;
        }
        
        return dataSource.length - audioDataOffset;
    }
}

-(NSString*) description
{
    return [[self queueItemId] description];
}

@end

@interface AudioPlayer()
@property (readwrite) AudioPlayerInternalState internalState;

-(void) processQueue:(BOOL)skipCurrent;
-(void) createAudioQueue;
-(void) enqueueBuffer;
-(void) resetAudioQueue;
-(BOOL) startAudioQueue;
-(void) stopAudioQueue;
-(BOOL) processRunloop;
-(void) wakeupPlaybackThread;
-(void) audioQueueFinishedPlaying:(QueueEntry*)entry;
-(void) processSeekToTime;
-(void) didEncounterError:(AudioPlayerErrorCode)errorCode;
-(void) setInternalState:(AudioPlayerInternalState)value;
-(void) processDidFinishPlaying:(QueueEntry*)entry withNext:(QueueEntry*)next;
-(void) handlePropertyChangeForFileStream:(AudioFileStreamID)audioFileStreamIn fileStreamPropertyID:(AudioFileStreamPropertyID)propertyID ioFlags:(UInt32*)ioFlags;
-(void) handleAudioPackets:(const void*)inputData numberBytes:(UInt32)numberBytes numberPackets:(UInt32)numberPackets packetDescriptions:(AudioStreamPacketDescription*)packetDescriptions;
-(void) handleAudioQueueOutput:(AudioQueueRef)audioQueue buffer:(AudioQueueBufferRef)buffer;
-(void) handlePropertyChangeForQueue:(AudioQueueRef)audioQueue propertyID:(AudioQueuePropertyID)propertyID;
@end

static void AudioFileStreamPropertyListenerProc(void* clientData, AudioFileStreamID audioFileStream, AudioFileStreamPropertyID	propertyId, UInt32* flags)
{	
	AudioPlayer* player = (__bridge AudioPlayer*)clientData;
    
	[player handlePropertyChangeForFileStream:audioFileStream fileStreamPropertyID:propertyId ioFlags:flags];
}

static void AudioFileStreamPacketsProc(void* clientData, UInt32 numberBytes, UInt32 numberPackets, const void* inputData, AudioStreamPacketDescription* packetDescriptions)
{
	AudioPlayer* player = (__bridge AudioPlayer*)clientData;
    
	[player handleAudioPackets:inputData numberBytes:numberBytes numberPackets:numberPackets packetDescriptions:packetDescriptions];
}

static void AudioQueueOutputCallbackProc(void* clientData, AudioQueueRef audioQueue, AudioQueueBufferRef buffer)
{
	AudioPlayer* player = (__bridge AudioPlayer*)clientData;
    
	[player handleAudioQueueOutput:audioQueue buffer:buffer];
}

static void AudioQueueIsRunningCallbackProc(void* userData, AudioQueueRef audioQueue, AudioQueuePropertyID propertyId)
{
	AudioPlayer* player = (__bridge AudioPlayer*)userData;
    
	[player handlePropertyChangeForQueue:audioQueue propertyID:propertyId];
}

@implementation AudioPlayer
@synthesize delegate, internalState, state;

-(AudioPlayerInternalState) internalState
{
    return internalState;
}

-(void) setInternalState:(AudioPlayerInternalState)value
{
    if (value == internalState)
    {
        return;
    }
    
    internalState = value;
    
    if ([self.delegate respondsToSelector:@selector(internalStateChanged:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^
        {
            [self.delegate audioPlayer:self internalStateChanged:internalState];
        });
    }

    AudioPlayerState newState;
    
    switch (internalState)
    {
        case AudioPlayerInternalStateInitialised:
            newState = AudioPlayerStateReady;
            break;
        case AudioPlayerInternalStateRunning:
        case AudioPlayerInternalStateStartingThread:
        case AudioPlayerInternalStateWaitingForData:
        case AudioPlayerInternalStateWaitingForQueueToStart:
        case AudioPlayerInternalStatePlaying:
            newState = AudioPlayerStatePlaying;
            break;
        case AudioPlayerInternalStateStopping:
        case AudioPlayerInternalStateStopped:
            newState = AudioPlayerStateStopped;
            break;
        case AudioPlayerInternalStatePaused:
            newState = AudioPlayerStatePaused;
            break;
        case AudioPlayerInternalStateDisposed:
            newState = AudioPlayerStateDisposed;
            break;
        case AudioPlayerInternalStateError:
            newState = AudioPlayerStateError;
            break;
    }
    
    if (newState != self.state)
    {
        self.state = newState;
     
        dispatch_async(dispatch_get_main_queue(), ^
        {
            [self.delegate audioPlayer:self stateChanged:self.state];
        });
    }
}

-(AudioPlayerStopReason) stopReason
{
    return stopReason;
}

-(BOOL) audioQueueIsRunning
{
    UInt32 isRunning;
    UInt32 isRunningSize = sizeof(isRunning);
    
    AudioQueueGetProperty(audioQueue, kAudioQueueProperty_IsRunning, &isRunning, &isRunningSize);
    
    return isRunning ? YES : NO;
}

-(id) init
{
    return [self initWithNumberOfAudioQueueBuffers:AudioPlayerDefaultNumberOfAudioQueueBuffers andReadBufferSize:AudioPlayerDefaultReadBufferSize];
}

-(id) initWithNumberOfAudioQueueBuffers:(int)numberOfAudioQueueBuffers andReadBufferSize:(int)readBufferSizeIn
{
    if (self = [super init])
    {
		fastApiSerialQueue = dispatch_queue_create("AudioPlayer.fastepi", 0);
		
        readBufferSize = readBufferSizeIn;
        readBuffer = calloc(sizeof(UInt8), readBufferSize);
        
        audioQueueBufferCount = numberOfAudioQueueBuffers;
        audioQueueBuffer = calloc(sizeof(AudioQueueBufferRef), audioQueueBufferCount);
        
        audioQueueBufferRefLookupCount = audioQueueBufferCount * 2;        
        audioQueueBufferLookup = calloc(sizeof(AudioQueueBufferRefLookupEntry), audioQueueBufferRefLookupCount);
        
        packetDescs = calloc(sizeof(AudioStreamPacketDescription), audioQueueBufferCount);
        bufferUsed = calloc(sizeof(bool), audioQueueBufferCount);
        
        pthread_mutex_init(&queueBuffersMutex, NULL);
        pthread_cond_init(&queueBufferReadyCondition, NULL);
               
        threadFinishedCondLock = [[NSConditionLock alloc] initWithCondition:0];
        
        self.internalState = AudioPlayerInternalStateInitialised;
        
        upcomingQueue = [[NSMutableArray alloc] init];
        bufferingQueue = [[NSMutableArray alloc] init];
    }
    
    return self;
}

-(void) dealloc
{
	dispatch_release(fastApiSerialQueue);
	
    pthread_mutex_destroy(&queueBuffersMutex);
    pthread_cond_destroy(&queueBufferReadyCondition);
    
    if (audioFileStream)
    {
        AudioFileStreamClose(audioFileStream);
    }
    
    if (audioQueue)
    {
        AudioQueueDispose(audioQueue, true);
    }
    
    free(bufferUsed);
    free(readBuffer);
    free(packetDescs);
    free(audioQueueBuffer);
    free(audioQueueBufferLookup);
}

-(void) startSystemBackgroundTask
{
	@synchronized(self)
	{
		if (backgroundTaskId != UIBackgroundTaskInvalid)
		{
			return;
		}
		
		backgroundTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^
		{
			[self stopSystemBackgroundTask];
		}];
	}
}

-(void) stopSystemBackgroundTask
{
	@synchronized(self)
	{
		if (backgroundTaskId != UIBackgroundTaskInvalid) 
		{
			[[UIApplication sharedApplication] endBackgroundTask:backgroundTaskId];
			
			backgroundTaskId = UIBackgroundTaskInvalid;
		}
	}
}

-(DataSource*) dataSourceFromURL:(NSURL*)url
{
    DataSource* retval;
    
    if ([url.scheme isEqualToString:@"file"])
    {
        retval = [[LocalFileDataSource alloc] initWithFilePath:url.path];
    }
    else
    {
        retval = [[HttpDataSource alloc] initWithURL:url];
    }

    return retval;
}

-(void) clearQueue
{
    @synchronized(self)
    {
        [upcomingQueue removeAllObjects];
    }
}

-(void) play:(NSURL*)url
{
	[self setDataSource:[self dataSourceFromURL:url] withQueueItemId:url];
}

-(void) setDataSource:(DataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId
{
	dispatch_async(fastApiSerialQueue, ^
	{
		@synchronized(self)
		{
			[self startSystemBackgroundTask];
			
			[self clearQueue];
			
			[upcomingQueue enqueue:[[QueueEntry alloc] initWithDataSource:dataSourceIn andQueueItemId:queueItemId]];
		 
			self.internalState = AudioPlayerInternalStateInitialised;
			[self processQueue:YES];
		}
	});
}

-(void) queueDataSource:(DataSource*)dataSourceIn withQueueItemId:(NSObject*)queueItemId
{
	dispatch_async(fastApiSerialQueue, ^
	{
		@synchronized(self)
		{
			[upcomingQueue enqueue:[[QueueEntry alloc] initWithDataSource:dataSourceIn andQueueItemId:queueItemId]];
			
			[self processQueue:NO];
		}
	});
}

-(void) handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID ioFlags:(UInt32*)ioFlags
{
	OSStatus error;

    switch (inPropertyID)
    {
        case kAudioFileStreamProperty_DataOffset:
        {
            SInt64 offset;
            UInt32 offsetSize = sizeof(offset);
            
            AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset);
            
            currentlyReadingEntry->parsedHeader = YES;
            currentlyReadingEntry->audioDataOffset = offset;
        }
        break;
        case kAudioFileStreamProperty_DataFormat:
        {
            AudioStreamBasicDescription newBasicDescription;
            UInt32 size = sizeof(newBasicDescription);

            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &size, &newBasicDescription);
            
            currentlyReadingEntry->audioStreamBasicDescription = newBasicDescription;
            
            currentlyReadingEntry->sampleRate = currentlyReadingEntry->audioStreamBasicDescription.mSampleRate;
            currentlyReadingEntry->packetDuration = currentlyReadingEntry->audioStreamBasicDescription.mFramesPerPacket / currentlyReadingEntry->sampleRate;
            
            UInt32 packetBufferSize = 0;
            UInt32 sizeOfPacketBufferSize = sizeof(packetBufferSize);
            
            error = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfPacketBufferSize, &packetBufferSize);
            
            if (error || packetBufferSize == 0)
            {
                error = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfPacketBufferSize, &packetBufferSize);
                
                if (error || packetBufferSize == 0)
                {
                    currentlyReadingEntry->packetBufferSize = AudioPlayerDefaultPacketBufferSize;
                }
            }            
        }
        break;
        case kAudioFileStreamProperty_AudioDataByteCount:
        {
            UInt64 audioDataByteCount;
            UInt32 byteCountSize = sizeof(audioDataByteCount);
            
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &audioDataByteCount);
            
            currentlyReadingEntry->audioDataByteCount = audioDataByteCount;
        }
        break;
		case kAudioFileStreamProperty_ReadyToProducePackets:
        {
            discontinuous = YES;
        }
        break;
    }
}

-(void) handleAudioPackets:(const void*)inputData numberBytes:(UInt32)numberBytes numberPackets:(UInt32)numberPackets packetDescriptions:(AudioStreamPacketDescription*)packetDescriptionsIn
{
    if (currentlyReadingEntry == nil)
    {
        return;
    }
    
	if (audioQueue == nil || memcmp(&currentAudioStreamBasicDescription, &currentlyReadingEntry->audioStreamBasicDescription, sizeof(currentAudioStreamBasicDescription)) != 0)
    {
        [self createAudioQueue];
    }
    
    if (discontinuous)
    {
        discontinuous = NO;
    }
    
    if (packetDescriptionsIn)
    {
        // VBR
        
        for (int i = 0; i < numberPackets; i++)
        {
            SInt64 packetOffset = packetDescriptionsIn[i].mStartOffset;
            SInt64 packetSize = packetDescriptionsIn[i].mDataByteSize;
            int bufSpaceRemaining;
        
            if (currentlyReadingEntry->processedPacketsSizeTotal < 0xfffff)
            {
                OSAtomicAdd32(packetSize, &currentlyReadingEntry->processedPacketsSizeTotal);
                OSAtomicIncrement32(&currentlyReadingEntry->processedPacketsCount);
            }
            
            if (packetSize > currentlyReadingEntry->packetBufferSize)
            {
                return;
            }
            
            bufSpaceRemaining = currentlyReadingEntry->packetBufferSize - bytesFilled;            
            
            if (bufSpaceRemaining < packetSize)
            {
                [self enqueueBuffer];
            }
            
            if (bytesFilled + packetSize > currentlyReadingEntry->packetBufferSize)
            {
                return;
            }
            
            AudioQueueBufferRef bufferToFill = audioQueueBuffer[fillBufferIndex];
            memcpy((char*)bufferToFill->mAudioData + bytesFilled, (const char*)inputData + packetOffset, packetSize);
            
            packetDescs[packetsFilled] = packetDescriptionsIn[i];
            packetDescs[packetsFilled].mStartOffset = bytesFilled;
            
            bytesFilled += packetSize;
            packetsFilled++;
            
            int packetsDescRemaining = audioQueueBufferCount - packetsFilled;
            
            if (packetsDescRemaining <= 0)
            {
                [self enqueueBuffer];
            }
        }
    }
    else 
    {
        // CBR
        
    	int offset = 0;
        
		while (numberBytes)
		{
			int bytesLeft = AudioPlayerDefaultPacketBufferSize - bytesFilled;
            
			if (bytesLeft < numberBytes)
			{
				[self enqueueBuffer];
			}
			
			@synchronized(self)
			{
				int copySize;
				bytesLeft = AudioPlayerDefaultPacketBufferSize - bytesFilled;

				if (bytesLeft < numberBytes)
				{
					copySize = bytesLeft;
				}
				else
				{
					copySize = numberBytes;
				}

				if (bytesFilled > currentlyPlayingEntry->packetBufferSize)
				{
					return;
				}
				
				AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
				memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)(inputData + offset), copySize);
                
				bytesFilled += copySize;
				packetsFilled = 0;
				numberBytes -= copySize;
				offset += copySize;
			}
		}
    }
}

-(void) handleAudioQueueOutput:(AudioQueueRef)audioQueueIn buffer:(AudioQueueBufferRef)bufferIn
{
    int bufferIndex = -1;
    
    if (audioQueueIn != audioQueue)
    {
        return;
    }
    
    if (currentlyPlayingEntry)
    {
        currentlyPlayingEntry->bytesPlayed += bufferIn->mAudioDataByteSize;
    }
    
    int index = (int)bufferIn % audioQueueBufferRefLookupCount;
    
    for (int i = 0; i < audioQueueBufferCount; i++)
    {
        if (audioQueueBufferLookup[index].ref == bufferIn)
        {
            bufferIndex = audioQueueBufferLookup[index].bufferIndex;
            
            break;
        }
        
        index++;
        index %= audioQueueBufferRefLookupCount;
    }
        
    audioPacketsPlayedCount++;
	
	if (bufferIndex == -1)
	{
		[self didEncounterError:AudioPlayerErrorUnknownBuffer];
        
		pthread_mutex_lock(&queueBuffersMutex);
		pthread_cond_signal(&queueBufferReadyCondition);
		pthread_mutex_unlock(&queueBuffersMutex);
        
		return;
	}
	
    pthread_mutex_lock(&queueBuffersMutex);

    bufferUsed[bufferIndex] = false;
    numberOfBuffersUsed--;
    
    if (!audioQueueFlushing)
    {
        QueueEntry* entry = currentlyPlayingEntry;
        
        if (entry != nil)
        {
            if (entry.bufferIndex <= audioPacketsPlayedCount && entry.bufferIndex != -1)
            {
                entry.bufferIndex = -1;
                
                if (playbackThread)
                {
                    CFRunLoopPerformBlock([playbackThreadRunLoop getCFRunLoop], NSDefaultRunLoopMode, ^
                    {
                        [self audioQueueFinishedPlaying:entry];
                    });
                    
                    CFRunLoopWakeUp([playbackThreadRunLoop getCFRunLoop]);
                }
            }
        }
    }
    
    // No need to signal constantly if we're reseting the AudioQueue
    if ((audioQueueFlushing && numberOfBuffersUsed < 5) || !audioQueueFlushing)
    {
        pthread_cond_signal(&queueBufferReadyCondition);
    }
    
    pthread_mutex_unlock(&queueBuffersMutex);
}

-(void) handlePropertyChangeForQueue:(AudioQueueRef)audioQueueIn propertyID:(AudioQueuePropertyID)propertyId
{
    if (audioQueueIn != audioQueue)
    {
        return;
    }
    
    if (propertyId == kAudioQueueProperty_IsRunning)
    {                
        if (![self audioQueueIsRunning] && self.internalState == AudioPlayerInternalStateStopping)
        {            
            self.internalState = AudioPlayerInternalStateStopped;
        }
        else if (self.internalState == AudioPlayerInternalStateWaitingForQueueToStart)
        {
            [NSRunLoop currentRunLoop];
            
            self.internalState = AudioPlayerInternalStatePlaying;
        }
    }
}

-(void) enqueueBuffer
{
    @synchronized(self)
    {
		OSStatus error;
	
        if (audioFileStream == 0)
        {
            return;
        }
        
        if (self.internalState == AudioPlayerInternalStateStopped)
        {
            return;
        }
                
        pthread_mutex_lock(&queueBuffersMutex);
        
        bufferUsed[fillBufferIndex] = true;
        numberOfBuffersUsed++;
        
        pthread_mutex_unlock(&queueBuffersMutex);
        
        AudioQueueBufferRef buffer = audioQueueBuffer[fillBufferIndex];
        
        buffer->mAudioDataByteSize = bytesFilled;
        
        if (packetsFilled)
        {
            
            error = AudioQueueEnqueueBuffer(audioQueue, buffer, packetsFilled, packetDescs);
        }
        else
        {
            error = AudioQueueEnqueueBuffer(audioQueue, buffer, 0, NULL);
        }
        
        audioPacketsReadCount++;
        
        if (error)
        {
            return;
        }
        
        if (self.internalState == AudioPlayerInternalStateWaitingForData && numberOfBuffersUsed >= AudioPlayerBuffersNeededToStart)
        {
            if (![self startAudioQueue])
            {
                return;
            }
        }
        
        if (++fillBufferIndex >= audioQueueBufferCount)
        {
            fillBufferIndex = 0;
        }
        
        bytesFilled = 0;
        packetsFilled = 0;
    }

    pthread_mutex_lock(&queueBuffersMutex); 

    while (bufferUsed[fillBufferIndex])
    {
        pthread_cond_wait(&queueBufferReadyCondition, &queueBuffersMutex);
    }
       
    pthread_mutex_unlock(&queueBuffersMutex);
}

-(void) didEncounterError:(AudioPlayerErrorCode)errorCodeIn
{
    errorCode = errorCode;    
    self.internalState = AudioPlayerInternalStateError;
}

-(void) createAudioQueue
{
	OSStatus error;
	
	[self startSystemBackgroundTask];
	
    if (audioQueue)
    {
        AudioQueueStop(audioQueue, YES);
        AudioQueueDispose(audioQueue, YES);
        
        audioQueue = nil;
    }
    
    currentAudioStreamBasicDescription = currentlyPlayingEntry->audioStreamBasicDescription;
        
    error = AudioQueueNewOutput(&currentlyPlayingEntry->audioStreamBasicDescription, AudioQueueOutputCallbackProc, (__bridge void*)self, NULL, NULL, 0, &audioQueue);
    
    if (error)
    {
        return;
    }
    
    error = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, AudioQueueIsRunningCallbackProc, (__bridge void*)self);
    
    if (error)
    {
        return;
    }
    
#if TARGET_OS_IPHONE
    UInt32 val = kAudioQueueHardwareCodecPolicy_PreferHardware;
    
    error = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_HardwareCodecPolicy, &val, sizeof(UInt32));
    
    if (error)
    {
    }
#endif
        
    memset(audioQueueBufferLookup, 0, sizeof(AudioQueueBufferRefLookupEntry) * audioQueueBufferRefLookupCount);
    
    // Allocate AudioQueue buffers
    
    for (int i = 0; i < audioQueueBufferCount; i++)
    {
        error = AudioQueueAllocateBuffer(audioQueue, currentlyPlayingEntry->packetBufferSize, &audioQueueBuffer[i]);
        
        int hash = (int)audioQueueBuffer[i] % audioQueueBufferRefLookupCount;
        
        while (true)
        {
            if (audioQueueBufferLookup[hash].ref == 0)
            {
                audioQueueBufferLookup[hash].ref = audioQueueBuffer[i];
                audioQueueBufferLookup[hash].bufferIndex = i;
                
                break;
            }
            else
            {
                hash++;
                hash %= audioQueueBufferRefLookupCount;
            }
        }
        
        bufferUsed[i] = false;
        
        if (error)
        {
            return;
        }
    }
    
    audioPacketsReadCount = 0;
    audioPacketsPlayedCount = 0;
        
    // Get file cookie/magic bytes information
    
	UInt32 cookieSize;
	Boolean writable;
    
	error = AudioFileStreamGetPropertyInfo(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
    
	if (error)
	{
		return;
	}
    
	void* cookieData = calloc(1, cookieSize);
    
	error = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
    
	if (error)
	{
        free(cookieData);
        
		return;
	}
    
	error = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
    
	if (error)
	{
        free(cookieData);
        
		return;
	}
    
    free(cookieData);
}

-(double) duration
{
    if (newFileToPlay)
    {
        return 0;
    }
    
    QueueEntry* entry = currentlyPlayingEntry;
    
    if (entry == nil)
    {
        return 0;
    }
    
    return [entry duration];
}

-(double) progress
{
    if (seekToTimeWasRequested)
    {
        return requestedSeekTime;
    }
    
    if (newFileToPlay)
    {
        return 0;
    }
    
    QueueEntry* entry = currentlyPlayingEntry;
    
    return [entry progress];
}

-(void) wakeupPlaybackThread
{
	NSRunLoop* runLoop = playbackThreadRunLoop;
	
    if (runLoop)
    {
        CFRunLoopPerformBlock([runLoop getCFRunLoop], NSDefaultRunLoopMode, ^
        {
        	[self processRunloop];
        });
        
        CFRunLoopWakeUp([runLoop getCFRunLoop]);
    }
}

-(void) seekToTime:(double)value
{
    @synchronized(self)
    {
		BOOL seekAlreadyRequested = seekToTimeWasRequested;
		
        seekToTimeWasRequested = YES;
        requestedSeekTime = value;

        if (!seekAlreadyRequested)
        {
            [self wakeupPlaybackThread];
        }
    }
}

-(void) processQueue:(BOOL)skipCurrent
{   
	if (playbackThread == nil)
	{
		newFileToPlay = YES;
		
		playbackThread = [[NSThread alloc] initWithTarget:self selector:@selector(startInternal) object:nil];
		
		[playbackThread start];
		
		[self wakeupPlaybackThread];
	}
	else
	{
		if (skipCurrent)
		{
			newFileToPlay = YES;
			
			[self resetAudioQueue];
		}
		
		[self wakeupPlaybackThread];
	}
}

-(void) setCurrentlyReadingEntry:(QueueEntry*)entry andStartPlaying:(BOOL)startPlaying 
{
	OSStatus error;

    pthread_mutex_lock(&queueBuffersMutex);
    
    if (startPlaying)
    {
        if (audioQueue)
        {
            pthread_mutex_unlock(&queueBuffersMutex);

            [self resetAudioQueue];
            
            pthread_mutex_lock(&queueBuffersMutex);
        }
    }

    if (audioFileStream)
    {
        AudioFileStreamClose(audioFileStream);
        
        audioFileStream = 0;
    }
    
    error = AudioFileStreamOpen((__bridge void*)self, AudioFileStreamPropertyListenerProc, AudioFileStreamPacketsProc, kAudioFileM4AType, &audioFileStream);
    
    if (error)
    {
        return;
    }
    
    if (currentlyReadingEntry)
    {
        currentlyReadingEntry.dataSource.delegate = nil;
        [currentlyReadingEntry.dataSource unregisterForEvents];
        [currentlyReadingEntry.dataSource close];
    }
    
    currentlyReadingEntry = entry;
    currentlyReadingEntry.dataSource.delegate = self;
    [currentlyReadingEntry.dataSource registerForEvents:[NSRunLoop currentRunLoop]];
    
    if (startPlaying)
    {
        [bufferingQueue removeAllObjects];
        
        [self processDidFinishPlaying:currentlyPlayingEntry withNext:entry];        
    }
    else
    {
        [bufferingQueue enqueue:entry];
    }
    
    pthread_mutex_unlock(&queueBuffersMutex);
}

-(void) audioQueueFinishedPlaying:(QueueEntry*)entry
{
    pthread_mutex_lock(&queueBuffersMutex);
    
    QueueEntry* next = [bufferingQueue dequeue];
    
    [self processDidFinishPlaying:entry withNext:next];
    
    pthread_mutex_unlock(&queueBuffersMutex);
}

-(void) processDidFinishPlaying:(QueueEntry*)entry withNext:(QueueEntry*)next
{
    if (entry != currentlyPlayingEntry)
    {
        return;
    }

    NSObject* queueItemId = entry.queueItemId;
    double progress = [entry progress];
    double duration = [entry duration];
    
    BOOL nextIsDifferent = currentlyPlayingEntry != next;
    
    if (next)
    {
        if (nextIsDifferent)
        {
            next->seekTime = 0;

            seekToTimeWasRequested = NO;
        }
        
        currentlyPlayingEntry = next;
        currentlyPlayingEntry->bytesPlayed = 0;
        
        NSObject* playingQueueItemId = currentlyPlayingEntry.queueItemId;
        
        if (nextIsDifferent && entry)
        {
            dispatch_async(dispatch_get_main_queue(), ^
            {
                [self.delegate audioPlayer:self didFinishPlayingQueueItemId:queueItemId withReason:stopReason andProgress:progress andDuration:duration];
            });
        }
        
        if (nextIsDifferent)
        {
            dispatch_async(dispatch_get_main_queue(), ^
            {
                [self.delegate audioPlayer:self didStartPlayingQueueItemId:playingQueueItemId];
            });
        }
    }
    else
    {
        currentlyPlayingEntry = nil;
        
        if (currentlyReadingEntry == nil)
        {
            self.internalState = AudioPlayerInternalStateStopping;
        }
        
        if (nextIsDifferent && entry)
        {
            dispatch_async(dispatch_get_main_queue(), ^
            {
                [self.delegate audioPlayer:self didFinishPlayingQueueItemId:queueItemId withReason:stopReason andProgress:progress andDuration:duration];
            });
        }
    }
}

-(BOOL) processRunloop
{
    @synchronized(self)
    {
        if (self.internalState == AudioPlayerInternalStatePaused)
        {
            return YES;
        }
        else if (newFileToPlay)
        {
            QueueEntry* entry = [upcomingQueue dequeue];
            
            self.internalState = AudioPlayerInternalStateWaitingForData;
            
            [self setCurrentlyReadingEntry:entry andStartPlaying:YES];
            
            newFileToPlay = NO;                
            nextIsIncompatible = NO;
        }            
        else if (seekToTimeWasRequested && currentlyPlayingEntry && currentlyPlayingEntry != currentlyReadingEntry)
        {
            currentlyPlayingEntry.bufferIndex = -1;
            [self setCurrentlyReadingEntry:currentlyPlayingEntry andStartPlaying:YES];
            
            currentlyReadingEntry->parsedHeader = NO;
            [currentlyReadingEntry.dataSource seekToOffset:0];
            
            nextIsIncompatible = NO;
        }
        else if (currentlyReadingEntry == nil)
        {
            if (nextIsIncompatible && currentlyPlayingEntry != nil)
            {
                // Holding off cause next is incompatible
            }
            else
            {                    
                if (upcomingQueue.count > 0)
                {
                    QueueEntry* entry = [upcomingQueue dequeue];
                    
                    BOOL startPlaying = currentlyPlayingEntry == nil;
                    
                    [self setCurrentlyReadingEntry:entry andStartPlaying:startPlaying];                          
                }
                else if (currentlyPlayingEntry == nil)
                {
                    if (self.internalState != AudioPlayerInternalStateStopped)
                    {
                        [self stopAudioQueue];
                    }
                }
            }
        }
        else if (self.internalState == AudioPlayerInternalStateStopped && stopReason == AudioPlayerStopReasonUserAction)
        {
            [self stopAudioQueue];
            
            currentlyReadingEntry.dataSource.delegate = nil;
            [currentlyReadingEntry.dataSource unregisterForEvents];
            
            if (currentlyReadingEntry)
            {
                [self processDidFinishPlaying:currentlyPlayingEntry withNext:nil];
            }
            
            pthread_mutex_lock(&queueBuffersMutex);
            
            currentlyPlayingEntry = nil;
            currentlyReadingEntry = nil;
            seekToTimeWasRequested = NO;
            
            pthread_mutex_unlock(&queueBuffersMutex);
        }
        else if (self.internalState == AudioPlayerInternalStateStopped && stopReason == AudioPlayerStopReasonUserActionFlushStop)
        {
            currentlyReadingEntry.dataSource.delegate = nil;
            [currentlyReadingEntry.dataSource unregisterForEvents];
            
            if (currentlyReadingEntry)
            {
                [self processDidFinishPlaying:currentlyPlayingEntry withNext:nil];
            }
            
            pthread_mutex_lock(&queueBuffersMutex);
            currentlyPlayingEntry = nil;
            currentlyReadingEntry = nil;

            pthread_mutex_unlock(&queueBuffersMutex);
            
            [self resetAudioQueue];
        }
        
        if (disposeWasRequested)
        {
            return NO;
        }
    }
    
    if (currentlyReadingEntry && currentlyReadingEntry->parsedHeader && currentlyReadingEntry != currentlyPlayingEntry)
    {
        if (currentAudioStreamBasicDescription.mSampleRate != 0)
        {
            if (memcmp(&currentAudioStreamBasicDescription, &currentlyReadingEntry->audioStreamBasicDescription, sizeof(currentAudioStreamBasicDescription)) != 0)
            {
                [upcomingQueue skipQueue:[[QueueEntry alloc] initWithDataSource:currentlyReadingEntry.dataSource andQueueItemId:currentlyReadingEntry.queueItemId]];
                
                currentlyReadingEntry = nil;
                nextIsIncompatible = YES;
            }
        }
    }
    
    if (currentlyPlayingEntry && currentlyPlayingEntry->parsedHeader)
    {
        if (seekToTimeWasRequested && currentlyReadingEntry == currentlyPlayingEntry)
        {
            [self processSeekToTime];
			
            seekToTimeWasRequested = NO;
        }
    }
    
    return YES;
}

-(void) startInternal
{
    playbackThreadRunLoop = [NSRunLoop currentRunLoop];
    
    NSThread.currentThread.threadPriority = 1;
    
    bytesFilled = 0;
    packetsFilled = 0;
    
    [playbackThreadRunLoop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
    
    do
    {        
        [playbackThreadRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:5]];
        
        if (![self processRunloop])
        {
            break;
        }
    }
    while (true);
    
    disposeWasRequested = NO;
    seekToTimeWasRequested = NO;

    currentlyReadingEntry.dataSource.delegate = nil;
    currentlyPlayingEntry.dataSource.delegate = nil;
    
    currentlyReadingEntry = nil;
    currentlyPlayingEntry = nil;
    
    self.internalState = AudioPlayerInternalStateDisposed;    
    
    [threadFinishedCondLock lock];    
    [threadFinishedCondLock unlockWithCondition:1];
}

-(void) processSeekToTime
{
	OSStatus error;
    NSAssert(currentlyReadingEntry == currentlyPlayingEntry, @"playing and reading must be the same");
    
    if ([currentlyPlayingEntry calculatedBitRate] == 0.0 || currentlyPlayingEntry.dataSource.length <= 0)
    {
        return;
    }
    
    long long seekByteOffset = currentlyPlayingEntry->audioDataOffset + (requestedSeekTime / self.duration) * (currentlyReadingEntry.audioDataLengthInBytes);
    
    if (seekByteOffset > currentlyPlayingEntry.dataSource.length - (2 * currentlyPlayingEntry->packetBufferSize))
    {
        seekByteOffset = currentlyPlayingEntry.dataSource.length - 2 * currentlyPlayingEntry->packetBufferSize;
    }
    
    currentlyPlayingEntry->seekTime = requestedSeekTime;
    currentlyPlayingEntry->lastProgress = requestedSeekTime;
    
    double calculatedBitRate = [currentlyPlayingEntry calculatedBitRate];
    
    if (currentlyPlayingEntry->packetDuration > 0 && calculatedBitRate > 0)
    {
        UInt32 ioFlags = 0;
        SInt64 packetAlignedByteOffset;
        SInt64 seekPacket = floor(requestedSeekTime / currentlyPlayingEntry->packetDuration);
        
        error = AudioFileStreamSeek(audioFileStream, seekPacket, &packetAlignedByteOffset, &ioFlags);
        
        if (!error && !(ioFlags & kAudioFileStreamSeekFlag_OffsetIsEstimated))
        {
            double delta = ((seekByteOffset - (SInt64)currentlyPlayingEntry->audioDataOffset) - packetAlignedByteOffset) / calculatedBitRate * 8;
            
            currentlyPlayingEntry->seekTime -= delta;
            
            seekByteOffset = packetAlignedByteOffset + currentlyPlayingEntry->audioDataOffset;
        }
    }
        
    [currentlyReadingEntry.dataSource seekToOffset:seekByteOffset];
    
    if (seekByteOffset > 0)
    {
        discontinuous = YES;
    }    
        
    if (audioQueue)
    {
        [self resetAudioQueue];
    }
    
    currentlyPlayingEntry->bytesPlayed = 0;
}

-(BOOL) startAudioQueue
{
	OSStatus error;

    self.internalState = AudioPlayerInternalStateWaitingForQueueToStart;
    
    error = AudioQueueStart(audioQueue, NULL);
    
    if (error)
    {
		if (backgroundTaskId == UIBackgroundTaskInvalid)
		{
			[self startSystemBackgroundTask];
		}
		
        [self stopAudioQueue];
        [self createAudioQueue];
        
        AudioQueueStart(audioQueue, NULL);
    }
	
	[self stopSystemBackgroundTask];
    
    return YES;
}

-(void) stopAudioQueue
{    
	OSStatus error;
	
	if (!audioQueue)
    {
        self.internalState = AudioPlayerInternalStateStopped;
        
        return;
    }
    else
    {    
        audioQueueFlushing = YES;
        
        error = AudioQueueStop(audioQueue, true);
        
        audioQueue = nil;
    }
    
    if (error)
    {
        [self didEncounterError:AudioPlayerErrorQueueStopFailed];
    }
    
    pthread_mutex_lock(&queueBuffersMutex);
    
    if (numberOfBuffersUsed != 0)
    {
        numberOfBuffersUsed = 0;
        
        for (int i = 0; i < audioQueueBufferCount; i++)
        {
            bufferUsed[i] = false;
        }                
    }
    
    pthread_cond_signal(&queueBufferReadyCondition);
    pthread_mutex_unlock(&queueBuffersMutex);
    
    bytesFilled = 0;
    fillBufferIndex = 0;
    packetsFilled = 0;
    
    audioPacketsReadCount = 0;
    audioPacketsPlayedCount = 0;
    audioQueueFlushing = NO;
    
    self.internalState = AudioPlayerInternalStateStopped;
}

-(void) resetAudioQueue
{
	OSStatus error;
	
    if (!audioQueue)
    {
        return;
    }
    
    audioQueueFlushing = YES;
    
    error = AudioQueueReset(audioQueue);
    
    if (error)
    {
		dispatch_async(dispatch_get_main_queue(), ^
		{
			[self didEncounterError:AudioPlayerErrorQueueStopFailed];;
		});
    }
    
    pthread_mutex_lock(&queueBuffersMutex);
    
    if (numberOfBuffersUsed != 0)
    {
        numberOfBuffersUsed = 0;
        
        for (int i = 0; i < audioQueueBufferCount; i++)
        {
            bufferUsed[i] = false;
        }                
    }
    
    pthread_cond_signal(&queueBufferReadyCondition);
    pthread_mutex_unlock(&queueBuffersMutex);
    
    bytesFilled = 0;
    fillBufferIndex = 0;
    packetsFilled = 0;
    
    if (currentlyPlayingEntry)
    {
        currentlyPlayingEntry->lastProgress = 0;
    }

    audioPacketsReadCount = 0;
    audioPacketsPlayedCount = 0;
    audioQueueFlushing = NO;
}

-(void) dataSourceDataAvailable:(DataSource*)dataSourceIn
{
	OSStatus error;

    if (currentlyReadingEntry.dataSource != dataSourceIn)
    {
        return;
    }
    
    if (!currentlyReadingEntry.dataSource.hasBytesAvailable)
    {
        return;
    }
    
    int read = [currentlyReadingEntry.dataSource readIntoBuffer:readBuffer withSize:readBufferSize];
    
    if (read == 0)
    {
        return;
    }
    
    if (read < 0)
    {
        // iOS will shutdown network connections if the app is backgrounded (i.e. device is locked when player is paused)
        // We try to reopen -- should probably add a back-off protocol in the future
        
        long long position = currentlyReadingEntry.dataSource.position;
        
        [currentlyReadingEntry.dataSource seekToOffset:position];
        
        return;
    }
    
    int flags = 0;
    
    if (discontinuous)
    {
        flags = kAudioFileStreamParseFlag_Discontinuity;
    }
    
    error = AudioFileStreamParseBytes(audioFileStream, read, readBuffer, flags);
    
    if (error)
    {
        if (dataSourceIn == currentlyPlayingEntry.dataSource)
        {
            [self didEncounterError:AudioPlayerErrorStreamParseBytesFailed];
        }
        
        return;
    }
}

-(void) dataSourceErrorOccured:(DataSource*)dataSourceIn
{
    if (currentlyReadingEntry.dataSource != dataSourceIn)
    {
        return;
    }
    
    [self didEncounterError:AudioPlayerErrorDataNotFound];
}

-(void) dataSourceEof:(DataSource*)dataSourceIn
{
    if (currentlyReadingEntry.dataSource != dataSourceIn)
    {
        return;
    }
    
    if (bytesFilled)
    {
        [self enqueueBuffer];
    }
    
    NSObject* queueItemId = currentlyReadingEntry.queueItemId;
    
    dispatch_async(dispatch_get_main_queue(), ^
    {
        [self.delegate audioPlayer:self didFinishBufferingSourceWithQueueItemId:queueItemId];
    });

    @synchronized(self)
    {
        if (audioQueue)
        {
            currentlyReadingEntry.bufferIndex = audioPacketsReadCount;
            currentlyReadingEntry = nil;
        }
        else
        {
            stopReason = AudioPlayerStopReasonEof;
            self.internalState = AudioPlayerInternalStateStopped;
        }
    }
}

-(void) pause
{
    @synchronized(self)
    {
		OSStatus error;
        
        if (self.internalState != AudioPlayerInternalStatePaused)
        {
            self.internalState = AudioPlayerInternalStatePaused;
            
            if (audioQueue)
            {
                error = AudioQueuePause(audioQueue);
                
                if (error)
                {
                    [self didEncounterError:AudioPlayerErrorQueuePauseFailed];
                    
                    return;
                }
            }
            
            [self wakeupPlaybackThread];
        }
    }
}

-(void) resume
{
    @synchronized(self)
    {
		OSStatus error;
		
        if (self.internalState == AudioPlayerInternalStatePaused)
        {
            self.internalState = AudioPlayerInternalStatePlaying;
            
            if (seekToTimeWasRequested)
            {
                [self resetAudioQueue];
            }
            
            error = AudioQueueStart(audioQueue, 0);
            
            if (error)
            {
                [self didEncounterError:AudioPlayerErrorQueueStartFailed];
                
                return;
            }
            
            [self wakeupPlaybackThread];
        }
    }
}

-(void) stop
{
    @synchronized(self)
    {
        if (self.internalState == AudioPlayerInternalStateStopped)
        {
            return;
        }
        
        stopReason = AudioPlayerStopReasonUserAction;
        self.internalState = AudioPlayerInternalStateStopped;
		
		[self wakeupPlaybackThread];
    }
}

-(void) flushStop
{
    @synchronized(self)
    {
        if (self.internalState == AudioPlayerInternalStateStopped)
        {
            return;
        }
        
        stopReason = AudioPlayerStopReasonUserActionFlushStop;
        self.internalState = AudioPlayerInternalStateStopped;
		
		[self wakeupPlaybackThread];
    }
}

-(void) stopThread
{
    BOOL wait = NO;
    
    @synchronized(self)
    {
        disposeWasRequested = YES;
        
        if (playbackThread && playbackThreadRunLoop)
        {
            wait = YES;
            
            CFRunLoopStop([playbackThreadRunLoop getCFRunLoop]);
        }
    }
    
    if (wait)
    {
        [threadFinishedCondLock lockWhenCondition:1];
        [threadFinishedCondLock unlockWithCondition:0];
    }
}

-(void) dispose
{
    [self stop];
    [self stopThread];
}

@end
