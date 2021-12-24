// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../governance/InitializableOwner.sol";
import "../base/BasicMetaTransaction.sol";
import "../interfaces/IDsgNft.sol";
import "../interfaces/IUserProfile.sol";

contract Invitation is InitializableOwner, BasicMetaTransaction {

    using SafeMath for uint256;

    struct CodeLock {
        address user;
        uint256 lockedAt;
    }

    struct CodeInfo {
        address generator;
        uint8 state; // 1.unused 2.used
    }

    uint8 constant CODE_STATE_UNUSED = 1;
    uint8 constant CODE_STATE_USED = 2;

    IERC721 public nft;
    IUserProfile public userProfile;

    mapping(uint256 => uint) public nftGenCodeCount; // Count of invitation codes generated by nft
    mapping(bytes32 => CodeInfo) public codeInfo; 
    mapping(bytes32 => CodeLock) public codeLock;

    uint256 public codeLockDuration;
    uint256 public maxGenCodeCount;


    event Exchange(address indexed sender, string indexed code, uint256 indexed createdID, uint256 existedID, uint256 color);

    // mint to.
    IDsgNft public _toToken;

    uint8 constant MAX_DEPTH = 16;
    uint32 constant MAX_DIF = (1 << 5) - 1;
    uint8 constant MOVE = 5;

    // parse ntf , 
    uint8[MAX_DEPTH] public tokenMax;
    // limit diff. if 0  this select unlimit ,
    uint8[MAX_DEPTH][MAX_DIF] public limitDiff;
    // how many select created.
    uint8[MAX_DEPTH][MAX_DIF] public createdDiff;

    // 0xff R
    // 0xff G
    // 0xff B
    // 0xff alpha  
    uint256 constant MAX_COLOR = 0xffffffff;

    // 
    uint8 public now_length = 0;

    // DsgNft _toToken nft,
    mapping(uint256 => address) public  _nft_address;

    uint256 public created_count = 0;

    constructor() public {

    }

    function initialize(IERC721 nft_, address _to_token, address userProfile_) public {
        super._initialize();

        nft = nft_;
        _toToken = IDsgNft(_to_token);
        userProfile = IUserProfile(userProfile_);
        codeLockDuration = 10 minutes;
        maxGenCodeCount = 3;
    }

    // codeHash: keccak256(code)
    function genCodes(uint256 nftId, bytes32[] memory codeHashs) public {
        (,, uint256 uTokenId, ,) = userProfile.getUserView(msgSender());
        require(nft.ownerOf(nftId) == msgSender() || (uTokenId >= 0 && nftId == uTokenId), "not the nft owner");

        uint count = nftGenCodeCount[nftId];
        require(count + codeHashs.length <= maxGenCodeCount, "exceeds the maximum number that can be generated");

        for(uint i = 0; i < codeHashs.length; ++i) {
            CodeInfo storage info = codeInfo[codeHashs[i]];
            require(info.state == 0, "code alread used");

            info.state = CODE_STATE_UNUSED;
            info.generator = msgSender();
        }

        nftGenCodeCount[nftId] = count + codeHashs.length;
    }

    function lockCode(bytes32 halfHash) public {
        CodeLock storage cl = codeLock[halfHash];
        require(cl.lockedAt.add(codeLockDuration) > block.timestamp, "already locked");

        cl.user = msgSender();
        cl.lockedAt = block.timestamp;
    }

    function exchange(string memory nickname, string calldata code, uint256 created, uint256 bg_color) public returns(uint256 createTokenID) {
        require(_nft_address[created] == address(0), "id is crated.");
        require(MAX_COLOR >=  bg_color, "invalid is color.");

        bytes32 codeHash = keccak256(bytes(code));
        CodeInfo storage info = codeInfo[codeHash];
        require(info.state == CODE_STATE_UNUSED, "bad state");

        info.state = CODE_STATE_USED;

        bytes32 codeHashHalf = keccak256(abi.encodePacked(code[:8]));
        require(codeLock[codeHashHalf].user == msgSender(), "not the locker");


        string memory res = uint256ToString(created);
        
        //mint nft.
        uint256 createdID = _toToken.mint(address(this), "DSG Avatar",  0, 0, res, address(this));

        // record 
        _nft_address[created] = msgSender();

        nft.approve(address(userProfile), createdID);
        userProfile.createProfileToUser(msgSender(), nickname, address(nft), createdID, info.generator);
        
        // emit event.
        emit Exchange(msg.sender, code, createdID, created, bg_color);
        
        return createdID;
    }

    function setMaxDepth(uint8 index, uint8 limit) onlyOwner public {
        require(index < MAX_DEPTH, "outof index(16).");
        require(limit > 0, "limit require > 0.");
        require(limit <= MAX_DIF, "outof index(32).");

        tokenMax[index] = limit - 1;
    }

    function setOneLimit(uint8 index, uint8 limit, uint8 maxSize) onlyOwner public {
        require(limit < tokenMax[index], "invalid index - limit.");

        limitDiff[index][limit] = maxSize;
    }

    function setDepth(uint8 depth)  onlyOwner public {
        now_length = depth;
    }

    function getLimitSize(uint8 index) public view returns( uint8[] memory) {
        
        uint8[] memory dif =  new uint8[](tokenMax[index]+1);
        
        for (uint8 i = 0; i <= tokenMax[index];i++){
            dif[i] = limitDiff[index][i];
        }
        
        return dif;
    }

    function getCreatedSize(uint8 index) public view returns( uint8[] memory) {
        uint8[] memory dif =  new uint8[](tokenMax[index]+1);
        
        for (uint8 i = 0; i <= tokenMax[index];i++){
            dif[i] = createdDiff[index][i];
        }
        
        return dif;
    }

    function checkTokenID(uint256 createID) public view returns(bool) {
        // must first != 0.
        require(tokenMax[0] != 0,"please init setMaxDepth.");

        uint8[] memory dif  = DecodeToken(createID);
        
        require(dif.length == now_length, "invalid length createid");
        
        for (uint8 i = 0; i < dif.length; i++){
            uint8 select = dif[i];

            if (select > tokenMax[i]) {
                return false;
            }

            if ( limitDiff[i][select] != 0 && createdDiff[i][select] + 1 > limitDiff[i][select] ) {
                return false;
            }
        }
        
        return true;
    }

    function encodeToken(uint8[] memory dif) public view returns(uint256 tokenID)  {
        require(dif.length == now_length, "length must == now_length");

        for(uint8 i = 0; i < now_length;i++){
            require(dif[i] >= 0, "invalid dif");
            require(dif[i] <= tokenMax[i], "outof different.");
            tokenID = (tokenID << (MOVE)) + dif[i];
        }
        return tokenID;
    }

    function DecodeToken(uint256 tokenID) public view returns(uint8[] memory ) {
        
        uint8[] memory dif =  new uint8[](now_length);

        for (uint8 i = 0; i < now_length; i++){
            dif[now_length - i - 1] = uint8( tokenID & (MAX_DIF)) ;
            tokenID = tokenID >> MOVE;
        }
        
        return dif;
    }

    function uint256ToString(uint i) public pure returns (string memory) {
        
        if (i == 0) return "0";
        
        uint j = i;
        uint length;
        
        while (j != 0) {
            length++;
            j = j >> 4;
        }
        
        uint mask = 15;
        bytes memory bstr = new bytes(length);
        uint k = length - 1;
        
        while (i != 0) {
            uint curr = (i & mask);
            bstr[k--] = bytes1(curr > 9 ? uint8(55 + curr ) : uint8(48 + curr)); // 55 = 65 - 10
            i = i >> 4;
        }
        
        return string(bstr);
    }

    function getView() public view returns(address nft_, address userProfile_, uint256 codeLockDuration_, uint256 maxGenCodeCount_, address toToken_) {
        nft_ = address(nft);
        userProfile_ = address(userProfile);
        codeLockDuration_ = codeLockDuration;
        maxGenCodeCount_ = maxGenCodeCount;
        toToken_ = address(_toToken);
    }

    function getCodeView(bytes32 codeHash) public view returns(address lockUser, uint256 lockedAt, address generator, uint8 state) {
        CodeLock storage cl = codeLock[codeHash];
        CodeInfo storage ci = codeInfo[codeHash];

        lockUser = cl.user;
        lockedAt = cl.lockedAt;
        generator = ci.generator;
        state = ci.state;
    }

    // implementation  received.
    function onERC721Received(address operator, address from, uint256 tokenId, bytes memory data) public  returns (bytes4) {
        
        //only receive the _nft staff
        if(address(this) != operator) {
            //invalid from nft
            return 0;
        }
        
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }
}