function [DATA, rez, uproj] = preprocessData(ops)

uproj = [];

if ~isempty(ops.chanMap)
    if ischar(ops.chanMap)
        load(ops.chanMap);
        try
            chanMapConn = chanMap(connected>1e-6);
            xc = xcoords(connected>1e-6);
            yc = ycoords(connected>1e-6);
        catch
            chanMapConn = 1+chanNums(connected>1e-6);
            xc = zeros(numel(chanMapConn), 1);
            yc = [1:1:numel(chanMapConn)]';
        end
    else
        chanMapConn = ops.chanMap;
        xc = zeros(numel(chanMapConn), 1);
        yc = [1:1:numel(chanMapConn)]';
        kcoords = ones(ops.Nchan, 1);
    end
else
    chanMapConn = 1:ops.Nchan;
    kcoords = ones(ops.Nchan, 1);
    xc = zeros(numel(chanMapConn), 1);
    yc = [1:1:numel(chanMapConn)]';
end
NchanTOT = ops.NchanTOT;
NT = ops.NT ;

d = dir(ops.fbinary);
ops.sampsToRead = floor(d.bytes/NchanTOT/2);

if ispc
    dmem         = memory;
    memfree      = dmem.MemAvailableAllArrays/8;
    memallocated = min(ops.ForceMaxRAMforDat, dmem.MemAvailableAllArrays) - memfree;
    memallocated = max(0, memallocated);
else
    memallocated = ops.ForceMaxRAMforDat;
end
nint16s      = memallocated/2;

NTbuff      = NT + 4*ops.ntbuff;
Nbatch      = ceil(d.bytes/2/NchanTOT /(NT-ops.ntbuff));
Nbatch_buff = floor(4/5 * nint16s/ops.Nchan /(NT-ops.ntbuff)); % factor of 4/5 for storing PCs of spikes
Nbatch_buff = min(Nbatch_buff, Nbatch);

%% load data into patches, filter, compute covariance
[b1, a1] = butter(3, ops.fshigh/ops.fs, 'high');

fprintf('Time %3.0fs. Loading raw data... \n', toc);
fid = fopen(ops.fbinary, 'r');
ibatch = 0;
Nchan = ops.Nchan;
if ops.GPU
    CC = gpuArray.zeros( Nchan,  Nchan, 'single');
else
    CC = zeros( Nchan,  Nchan, 'single');
end
if strcmp(ops.whitening, 'noSpikes')
    if ops.GPU
        nPairs = gpuArray.zeros( Nchan,  Nchan, 'single');
    else
        nPairs = zeros( Nchan,  Nchan, 'single');
    end
end
if ~exist('DATA', 'var')
    DATA = zeros(NT, ops.Nchan, Nbatch_buff, 'int16');
end

isproc = zeros(Nbatch, 1);
while 1
    ibatch = ibatch + ops.nSkipCov;
    
    offset = max(0, 2*NchanTOT*((NT - ops.ntbuff) * (ibatch-1) - 2*ops.ntbuff));
    if ibatch==1
        ioffset = 0;
    else
        ioffset = ops.ntbuff;
    end
    fseek(fid, offset, 'bof');
    buff = fread(fid, [NchanTOT NTbuff], '*int16');
    
    %         keyboard;
    
    if isempty(buff)
        break;
    end
    nsampcurr = size(buff,2);
    if nsampcurr<NTbuff
        buff(:, nsampcurr+1:NTbuff) = repmat(buff(:,nsampcurr), 1, NTbuff-nsampcurr);
    end
    if ops.GPU
        dataRAW = gpuArray(buff);
    else
        dataRAW = buff;
    end
    dataRAW = dataRAW';
    dataRAW = single(dataRAW);
    dataRAW = dataRAW(:, chanMapConn);
    
    datr = filter(b1, a1, dataRAW);
    datr = flipud(datr);
    datr = filter(b1, a1, datr);
    datr = flipud(datr);
    
    switch ops.whitening
        case 'noSpikes'
            smin      = my_min(datr, ops.loc_range, [1 2]);
            sd = std(datr, [], 1);
            peaks     = single(datr<smin+1e-3 & bsxfun(@lt, datr, ops.spkTh * sd));
            blankout  = 1+my_min(-peaks, ops.long_range, [1 2]);
            smin      = datr .* blankout;
            CC        = CC + (smin' * smin)/NT;
            nPairs    = nPairs + (blankout'*blankout)/NT;
        otherwise
            CC        = CC + (datr' * datr)/NT;
    end
    
    if ibatch<=Nbatch_buff
        DATA(:,:,ibatch) = gather_try(int16( datr(ioffset + (1:NT),:)));
        isproc(ibatch) = 1;
    end
end
CC = CC / ceil((Nbatch-1)/ops.nSkipCov);
switch ops.whitening
    case 'noSpikes'
        nPairs = nPairs/ibatch;
end
fclose(fid);
fprintf('Time %3.0fs. Channel-whitening filters computed. \n', toc);
switch ops.whitening
    case 'diag'
        CC = diag(diag(CC));
    case 'noSpikes'
        CC = CC ./nPairs;
end

if ops.whiteningRange<Inf
    ops.whiteningRange = min(ops.whiteningRange, Nchan);
    Wrot = whiteningLocal(gather(CC), yc, xc, ops.whiteningRange);
else
    %
    [E, D] 	= svd(CC);
    D = diag(D);
    eps 	= 1e-6;
    Wrot 	= E * diag(1./(D + eps).^.5) * E';
end
Wrot    = ops.scaleproc * Wrot;

fprintf('Time %3.0fs. Loading raw data and applying filters... \n', toc);

fid     = fopen(ops.fbinary, 'r');
fidW    = fopen(ops.fproc, 'w');

if strcmp(ops.initialize, 'fromData')
    i0 = 0;
    wPCA = ops.wPCA(:, 1:3);
    uproj = zeros(1e6,  size(wPCA,2) * Nchan, 'single');
end
%
for ibatch = 1:Nbatch
    if isproc(ibatch) %ibatch<=Nbatch_buff
        if ops.GPU
            datr = single(gpuArray(DATA(:,:,ibatch)));
        else
            datr = single(DATA(:,:,ibatch));
        end
    else
        offset = max(0, 2*NchanTOT*((NT - ops.ntbuff) * (ibatch-1) - 2*ops.ntbuff));
        if ibatch==1
            ioffset = 0;
        else
            ioffset = ops.ntbuff;
        end
        fseek(fid, offset, 'bof');
        
        buff = fread(fid, [NchanTOT NTbuff], '*int16');
        if isempty(buff)
            break;
        end
        nsampcurr = size(buff,2);
        if nsampcurr<NTbuff
            buff(:, nsampcurr+1:NTbuff) = repmat(buff(:,nsampcurr), 1, NTbuff-nsampcurr);
        end
        
        if ops.GPU
            dataRAW = gpuArray(buff);
        else
            dataRAW = buff;
        end
        dataRAW = dataRAW';
        dataRAW = single(dataRAW);
        dataRAW = dataRAW(:, chanMapConn);
        
        datr = filter(b1, a1, dataRAW);
        datr = flipud(datr);
        datr = filter(b1, a1, datr);
        datr = flipud(datr);
        
        datr = datr(ioffset + (1:NT),:);
    end
    
    datr    = datr * Wrot;
    
    if ops.GPU
        dataRAW = gpuArray(datr);
    else
        dataRAW = datr;
    end
    %         dataRAW = datr;
    dataRAW = single(dataRAW);
    dataRAW = dataRAW / ops.scaleproc;
    
    if strcmp(ops.initialize, 'fromData')
        % find isolated spikes
        [row, col, mu] = isolated_peaks(dataRAW, ops.loc_range, ops.long_range, ops.spkTh);
        
        % find their PC projections
        uS = get_PCproj(dataRAW, row, col, wPCA, ops.maskMaxChannels);
        
        uS = permute(uS, [2 1 3]);
        uS = reshape(uS,numel(row), Nchan * size(wPCA,2));
        
        if i0+numel(row)>size(uproj,1)
            uproj(1e6 + size(uproj,1), 1) = 0;
        end
        
        uproj(i0 + (1:numel(row)), :) = gather_try(uS);
        i0 = i0 + numel(row);
    end
    
    if ibatch<=Nbatch_buff
        DATA(:,:,ibatch) = gather_try(datr);
    else
        datcpu  = gather_try(int16(datr));
        fwrite(fidW, datcpu, 'int16');
    end
    
end

Wrot        = gather_try(Wrot);
rez.Wrot    = Wrot;

fclose(fidW);
fclose(fid);
if ops.verbose
    fprintf('Time %3.2f. Whitened data written to disk... \n', toc);
    fprintf('Time %3.2f. Preprocessing complete!\n', toc);
end





