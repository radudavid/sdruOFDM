
classdef NodeRX2 < handle %< matlab.System
    %#codegen
    properties
        estimate
        ObjPreambleDemod
        ObjDataDemod
        rx
        offsetCompensationValue
        USRPDACSamplingRate
        pSDRuReceiver
        pAGC
        pDetect
        numFreqToAverage
        
    end
    
    properties (Constant)
        pReceiveBufferLength = 5120;
    end
    
    
    methods
        function SetupParams(obj)

            % Setup Parameters
           [ obj.ObjPreambleDemod, obj.ObjDataDemod, ~, obj.rx ] = generateOFDMSignal;
           
           obj.rx.receiveBufferLength = ceil( obj.rx.frameLength*4 ); %Size of Buffer of sliding window
           
           obj.USRPDACSamplingRate = 100e6;
           obj.rx.DecimationFactor = obj.USRPDACSamplingRate/obj.rx.samplingFreq;
           
           obj.offsetCompensationValue = -7000;
           
           %Create memory structure to collect measurements for sync algorithms
           obj.numFreqToAverage = 15; %Number of frequency estimates to be averaged together for frequency corrections (Higher==More stability, Lower==More responsiveness)
           [obj.estimate, ~] = initializeOFDMSyncMemory_sdr( obj.rx.receiveBufferLength, obj.numFreqToAverage, obj.rx, false, obj.ObjPreambleDemod, obj.ObjDataDemod );
           
        end
        
        function SetupObjects(obj)
            % Gain control
            obj.pAGC = comm.AGC('UpdatePeriod', obj.pReceiveBufferLength);
            % USRP
            obj.pSDRuReceiver = comm.SDRuReceiver( '192.168.10.2', ...
                'CenterFrequency',      2.2e9 + obj.offsetCompensationValue, ...
                'DecimationFactor',     obj.rx.DecimationFactor,...
                'FrameLength',          obj.pReceiveBufferLength,...
                'OutputDataType',       'double',...
                'Gain',                 18);
            
            % CRC
            obj.pDetect = comm.CRCDetector([1 0 0 1], 'ChecksumsPerFrame',1);
            
            
        end
        
        
        function [recoveredMessage] = Run(obj)
            
            numFrames = 1; % Frames to capture
            lastFound = -2; %Flag for found frame, used for dup check
            numBuffersProcessed = 0; %Track received data, needed for separate indexing of processed and unprocessed data (processed==preamble found)
            
            messageBits = zeros(numFrames,tx.messageCharacters*7+3);%3 for CRC
            
            % String holder
            coder.varsize('recoveredMessage', [1, 80], [0 1]);
            recoveredMessage = '';
            
            % Timeout info
            buffersPerSecond = (100e6/DecimationFactor)/receiveBufferLength;
            timeoutDuration = buffersPerSecond*20;
            
            
            %% Process received data
            % Locate frames in buffer and compensate for channel affects
            numFrames = 1; % Number of frames to find
            while obj.estimate.numProcessed < numFrames
                
                %buffer = rChannel(windowIndex : windowIndex + obj.estimate.inputBufferLength - 1);% Add incoming samples to buffer
                buffer = step(obj.pSDRuReceiver);
                if sum(buffer)==0
                    % All zeros from radio (Bug?)
                    %disp('All zeros (Bug?)');
                    continue;
                end
                
                % Automatic Gain Control
                buffer = step(obj.pAGC, buffer);
                
                % Increment processed data index
                numBuffersProcessed = numBuffersProcessed + 1;
                
                %% Find preamble in buffer
                [obj.estimate.delay, obj.estimate.numPeaks] = locateOFDMFrame_sdr( tx.FFTLength, tx.shortPreambleOFDM, buffer);
                
                % Check if frame exists in correct location and whether it's duplicate
                FrameFound = ((obj.estimate.delay + tx.frameLength) < length(buffer) ) &&... %Check if full data frame exists in buffer
                    (obj.estimate.delay > -1 ) &&... %Check if preamble located
                    ((numBuffersProcessed-lastFound) >= 2 ); %Check if duplicate frame
                
                %% Recover found frame
                if FrameFound
                    
                    lastFound = numBuffersProcessed;%Flag frame as found so duplicate frames are not processed
                    obj.estimate.numProcessed = obj.estimate.numProcessed + 1;%Increment processed found frames
                    
                    % Extract single frame from input buffer
                    rFrame = buffer(obj.estimate.delay + 1 : obj.estimate.delay + tx.frameLength);
                    
                    % Correct frequency offset
                    [ rFreqShifted, obj.estimate ] = coarseOFDMFreqEst_sdr( rFrame, tx, obj.estimate);
                    % Equalize
                    [ RPostEqualizer, ~, obj.estimate] = equalizeOFDM( rFreqShifted, tx, obj.estimate, hPreambleDemod, hDataDemod );
                    
                    % Demod subcarriers
                    [ ~, obj.estimate, RHard ] = demodOFDMSubcarriers_sdr( RPostEqualizer, tx, obj.estimate );
                    
                    % Save for later decoding and CRC
                    messageBits(obj.estimate.numProcessed,:) = RHard;
                    
                end
                
                %% Timeout
                if numBuffersProcessed > timeoutDuration
                    %disp('PHY: Receiver timed out');
                    recoveredMessage = 'Timeout';
                    break;
                end
            end
            
            
            
            %% Print Messages
            for recMessage = 1:obj.estimate.numProcessed
                
                % CRC Check
                [msg, err] = step(obj.pDetect, messageBits(recMessage,:).'>0);
                
                if ~err
                    %Convert Bits to characters
                    message = char(OFDMbits2letters(msg > 0).');%messageBits(recMessage,1:end-3)
                    %Remove padding
                    messageEnd = strfind(message,'EOF');
                    if ~isempty(messageEnd)
                        recoveredMessage = message(1:messageEnd(1,1)-1);
                        disp(recoveredMessage);
                    end
                else
                    disp('CRC Message Failure');
                    recoveredMessage = 'CRC Error';
                end
            end
            
            
        end
        
        
    end
end

