// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IWJAX {
  function burnFrom(address, uint) external;    
  function mint(address, uint) external returns (bool);
}

contract Wjax2JaxBridge {

  uint chainId;
  
  uint public fee_percent = 5e5; // 0.5 %
  uint public minimum_fee_amount = 50; // 50 wjax

  address public admin;

  uint public penalty_amount = 0;

  address public penalty_wallet;

  IWJAX public wjax = IWJAX(0x643aC3E0cd806B1EC3e2c45f9A5429921422Cd74); 

  enum RequestStatus {Init, Released}

  struct Request {
    uint shard_id;
    uint amount;
    uint fee_amount;
    uint created_at;
    uint released_at;
    address from;
    RequestStatus status;
    string to;
    string local_txHash;
    string jaxnet_txHash;
  }

  Request[] public requests;

  mapping(address => uint[]) public user_requests;

  address[] public bridge_operators;
  mapping(address => uint) operating_limits;

  mapping(bytes32 => bool) proccessed_txd_hashes;

  event Deposit(uint request_id, uint shard_id, uint amount, uint fee_amount, address from, string to);
  event Release(uint request_id, string to, uint amount, string txHash);
  event Set_Fee(uint fee_percent, uint minimum_fee_amount);
  event Set_Operating_Limit(address operator, uint operating_limit);
  event Set_Penalty_Wallet(address wallet);
  event Set_Admin(address admin);
  event Add_Penalty_Amount(uint amount, bytes32 info_hash);
  event Subtract_Penalty_Amount(uint amount, bytes32 info_hash);

  constructor() {
    admin = msg.sender;
    uint _chainId;
    assembly {
        _chainId := chainid()
    }
    chainId = _chainId;
    penalty_wallet = msg.sender;
  }

  modifier onlyAdmin() {
    require(admin == msg.sender, "Only Admin can perform this operation.");
    _;
  }


  modifier onlyOperator() {
    require(isBridgeOperator(msg.sender), "Not a bridge operator");
    _;
  }

  function deposit(uint shard_id, uint amount, string calldata to) external 
  {
    require(shard_id >= 1 && shard_id <= 3, "Invalid shard id");
    require(amount > minimum_fee_amount, "Below minimum amount");
    uint request_id = requests.length;
    Request memory request;
    request.shard_id = shard_id;
    uint fee_amount = request.amount * fee_percent / 1e8;
    if(fee_amount < minimum_fee_amount) fee_amount = minimum_fee_amount;
    request.amount = amount - fee_amount;
    request.fee_amount = fee_amount;
    request.to = to;
    request.from = msg.sender;
    request.created_at = block.timestamp;
    requests.push(request);
    user_requests[msg.sender].push(request_id);
    wjax.burnFrom(msg.sender, amount);
    emit Deposit(request_id, shard_id, amount, fee_amount, msg.sender, to);
  }

  function release(
    uint request_id,
    uint shard_id,
    uint amount,
    address from,
    string calldata to,
    string calldata local_txHash,
    string calldata jaxnet_txHash
  ) external onlyOperator {
    Request storage request = requests[request_id];
    bytes32 jaxnet_txd_hash = keccak256(abi.encodePacked(jaxnet_txHash));
    bytes32 local_txd_hash = keccak256(abi.encodePacked(local_txHash));
    require(operating_limits[msg.sender] >= amount, "Amount exceeds operating limit");
    require(request.amount == amount, "Incorrect amount");
    require(request.status == RequestStatus.Init, "Invalid status");
    require(request.from == from, "Invalid sender address");
    require(request.shard_id == shard_id, "Invalid shard id");
    require(keccak256(abi.encodePacked(request.to)) == keccak256(abi.encodePacked(to)), "Destination address mismatch");
    require(proccessed_txd_hashes[jaxnet_txd_hash] == false, "Jaxnet TxHash already used");
    require(proccessed_txd_hashes[local_txd_hash] == false, "Local TxHash already used");
    request.jaxnet_txHash = jaxnet_txHash;
    request.local_txHash = local_txHash;
    request.released_at = block.timestamp;
    request.status = RequestStatus.Released;
    proccessed_txd_hashes[jaxnet_txd_hash] = true;
    proccessed_txd_hashes[local_txd_hash] = true;
    uint fee_amount = request.fee_amount;
    if(penalty_amount > 0) {
      if(penalty_amount > fee_amount) {
        wjax.mint(penalty_wallet, fee_amount);
        penalty_amount -= fee_amount;
      }
      else {
        wjax.mint(penalty_wallet, penalty_amount);
        wjax.mint(msg.sender, fee_amount - penalty_amount);
        penalty_amount -= penalty_amount;
      }
    }
    else {
      wjax.mint(msg.sender, fee_amount);
    }
    operating_limits[msg.sender] -= amount;
    emit Release(request_id, request.to, request.amount, jaxnet_txHash);
  }

  function get_user_requests(address user) external view returns(uint[] memory) {
    return user_requests[user];
  }

  function add_bridge_operator(address operator, uint operating_limit) external onlyAdmin {
    for(uint i = 0; i < bridge_operators.length; i += 1) {
      if(bridge_operators[i] == operator)
        revert("Already exists");
    }
    bridge_operators.push(operator);
    operating_limits[operator] = operating_limit;
  }

  function isBridgeOperator(address operator) public view returns(bool) {
    uint i = 0;
    for(; i < bridge_operators.length; i += 1) {
      if(bridge_operators[i] == operator)
        return true;
    } 
    return false;
  }

  function set_operating_limit(address operator, uint operating_limit) external onlyAdmin {
    require(isBridgeOperator(operator), "Not a bridge operator");
    operating_limits[operator] = operating_limit;
    emit Set_Operating_Limit(operator, operating_limit);
  }

  function set_fee(uint _fee_percent, uint _minimum_fee_amount) external onlyAdmin {
    fee_percent = _fee_percent;
    minimum_fee_amount = _minimum_fee_amount;
    emit Set_Fee(_fee_percent, _minimum_fee_amount);
  }

  function set_penalty_wallet(address _penalty_wallet) external onlyAdmin {
    penalty_wallet = _penalty_wallet;
    emit Set_Penalty_Wallet(_penalty_wallet);
  }

  function set_admin(address _admin) external onlyAdmin {
    admin = _admin;
    emit Set_Admin(_admin);
  }

  function add_penalty_amount(uint amount, bytes32 info_hash) external onlyAdmin {
    penalty_amount += amount;
    emit Add_Penalty_Amount(amount, info_hash);
  }

  function subtract_penalty_amount(uint amount, bytes32 info_hash) external onlyAdmin {
    require(penalty_amount >= amount, "over penalty amount");
    emit Subtract_Penalty_Amount(amount, info_hash);
  }
}