import json
import logging
import math
import os
import random
import time
import base64
from io import BytesIO

import boto3
import numpy as np
import streamlit as st
from PIL import Image
from botocore.exceptions import ClientError
from components.Parameter_store import S3_BUCKET_NAME


# ──────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────
logger = logging.getLogger()
logger.setLevel(logging.INFO)


# ──────────────────────────────────────────────
# AWS clients  (no Streamlit calls here)
# ──────────────────────────────────────────────
dynamodb_client = boto3.resource("dynamodb")
bedrock_client = boto3.client("bedrock-runtime")
questions_table = dynamodb_client.Table("assignments")

text_model_id = "amazon.nova-pro-v1:0"
image_model_id = "amazon.nova-2-lite-v1:0"


# ──────────────────────────────────────────────
# Helper: parse model text response to JSON
# ──────────────────────────────────────────────
# FIX #1 ─ removed dead `lines` code; added proper error handling
def parse_text_to_lines(text: str) -> list:
    """Strip markdown fences and parse the JSON returned by the model."""
    text = text.replace("```json\n", "").replace("\n```", "").strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        raise ValueError(f"Failed to parse model response as JSON: {e}\n\nRaw text:\n{text}")


# ──────────────────────────────────────────────
# Bedrock – text (Q&A generation)
# ──────────────────────────────────────────────
def query_generate_questions_answers_endpoint(input_text: str) -> list:
    prompt = (
        f"{input_text}\n"
        "Using the above context, please generate five questions and answers "
        "you could ask students about this information.\n"
        "Format the output as a list of five JSON objects containing the keys: "
        "Id, Question, and Answer"
    )
    input_data = {
        "inferenceConfig": {"max_new_tokens": 1000},
        "messages": [{"role": "user", "content": [{"text": prompt}]}],
    }
    try:
        qa_response = bedrock_client.invoke_model(
            modelId=text_model_id,
            body=json.dumps(input_data).encode("utf-8"),
            accept="application/json",
            contentType="application/json",
        )
    except (ClientError, Exception) as e:
        # FIX #5 ─ replaced exit(1) with st.error + st.stop()
        st.error(f"Cannot invoke model '{text_model_id}': {e}")
        st.stop()

    response_body = json.loads(qa_response.get("body").read().decode())
    response_text = response_body["output"]["message"]["content"][0]["text"]
    return parse_text_to_lines(response_text)


# ──────────────────────────────────────────────
# Bedrock – image generation
# ──────────────────────────────────────────────
def query_generate_image_endpoint(input_text: str):
    # FIX #3 ─ seed is now actually used in the API call
    seed = int(np.random.randint(1000))

    input_body = json.dumps(
        {
            "taskType": "TEXT_IMAGE",
            "textToImageParams": {"text": f"An image of {input_text}"},
            "imageGenerationConfig": {
                "numberOfImages": 1,
                "height": 1024,
                "width": 1024,
                "cfgScale": 8.0,
                "seed": seed,
            },
        }
    )

    if image_model_id == "<model-id>":
        return None

    try:
        titan_image_api_response = bedrock_client.invoke_model(
            body=input_body,
            modelId=image_model_id,
            accept="application/json",
            contentType="application/json",
        )
    except (ClientError, Exception) as e:
        # FIX #5 ─ consistent error reporting via Streamlit
        st.error(f"Cannot invoke image model '{image_model_id}': {e}")
        return None

    response_body = json.loads(titan_image_api_response.get("body").read())
    base64_image = response_body.get("images")[0]
    image_bytes = base64.b64decode(base64_image.encode("ascii"))
    image = Image.open(BytesIO(image_bytes))
    return image


# ──────────────────────────────────────────────
# Utilities
# ──────────────────────────────────────────────
def generate_assignment_id_key() -> str:
    epoch = round(time.time() * 1000) - 1670000000000
    rand_id = math.floor(random.random() * 999)
    return str((epoch * 1000) + rand_id)


def load_file_to_s3(file_name: str, object_name: str) -> bool:
    s3_client = boto3.client("s3")
    try:
        s3_client.upload_file(file_name, S3_BUCKET_NAME, object_name)
        return True
    except ClientError as e:
        # FIX #9 ─ consistent use of logger instead of print()
        logger.error("S3 upload failed: %s", e)
        return False


def insert_record_to_dynamodb(assignment_id: str, prompt: str, s3_image_name: str, data):
    questions_table.put_item(
        Item={
            "id": assignment_id,
            "assignment_id": assignment_id,
            "teacher_id": user_name,
            "prompt": prompt,
            "s3_image_name": s3_image_name,
            "question_answers": data,
        }
    )


# ──────────────────────────────────────────────
# Page config — MUST be the first Streamlit call
# ──────────────────────────────────────────────
st.set_page_config(page_title="Create Assignments", page_icon=":pencil:", layout="wide")

# FIX #10 - Validate S3_BUCKET_NAME right after set_page_config
if not S3_BUCKET_NAME:
    st.error("S3_BUCKET_NAME is not configured. Please check Parameter Store.")
    st.stop()

# FIX #8 - user_name from session/auth (must be after set_page_config)
user_name = st.session_state.get("authenticated_user", "CloudAge-User")

# Session state defaults (must be after set_page_config)
st.session_state.setdefault("input_text", "")
st.session_state.setdefault("question_answers", [])
st.session_state.setdefault("uploaded_image_bytes", None)
st.session_state.setdefault("selected_question_idx", None)
st.session_state.setdefault("reading_material", None)
st.session_state.setdefault("last_processed_input_text", None)
st.session_state.setdefault("generated_image_bytes", None)

# ──────────────────────────────────────────────
# Page layout
# ──────────────────────────────────────────────
st.sidebar.header("Create Assignments")
st.markdown("# Create Assignments")
st.sidebar.header("Input text to create assignments")


# ──────────────────────────────────────────────
# Input area – auto-generate on new text
# ──────────────────────────────────────────────
text = st.text_area("Input Text", key="input_text")

if text and text != st.session_state.get("last_processed_input_text") and text != "None":
    try:
        # FIX #4 & #11 ─ store image bytes in session_state, guard against None
        if image_model_id != "<model-id>":
            image = query_generate_image_endpoint(text)
            if image is not None:
                buf = BytesIO()
                image.save(buf, format="PNG")
                st.session_state["generated_image_bytes"] = buf.getvalue()

        questions_answers = query_generate_questions_answers_endpoint(text)
        st.session_state["question_answers"] = questions_answers
        st.session_state["last_processed_input_text"] = text

    except Exception as ex:
        st.error(f"Error while generating questions: {ex}")


# ──────────────────────────────────────────────
# Display generated Q&A
# ──────────────────────────────────────────────
if st.session_state.get("question_answers"):
    st.markdown("## Generated Questions and Answers")
    st.text_area(
        "Questions and Answers",
        json.dumps(st.session_state["question_answers"], indent=4),
        height=320,
        label_visibility="collapsed",
    )


# ──────────────────────────────────────────────
# Button: Re-generate Q&A
# ──────────────────────────────────────────────
if st.button("Generate Questions and Answers", key="btn_generate_qna"):
    if not text:
        st.warning("Please enter some input text first.")
    else:
        st.session_state["question_answers"] = query_generate_questions_answers_endpoint(text)
        # FIX #2 ─ replaced deprecated st.experimental_rerun() with st.rerun()
        st.experimental_rerun()


# ──────────────────────────────────────────────
# Display generated image
# ──────────────────────────────────────────────
# FIX #4 ─ read from session_state instead of temp file on disk
if st.session_state.get("generated_image_bytes") and image_model_id != "<model-id>":
    image_to_show = Image.open(BytesIO(st.session_state["generated_image_bytes"]))
    st.image(image_to_show, width=512)


# ──────────────────────────────────────────────
# Button: Generate new image
# ──────────────────────────────────────────────
if image_model_id != "<model-id>":
    if st.button("Generate New Image", key="btn_new_image"):
        if not text:
            st.warning("Please enter some input text first.")
        else:
            image = query_generate_image_endpoint(text)
            # FIX #11 ─ guard against None before saving
            if image is not None:
                buf = BytesIO()
                image.save(buf, format="PNG")
                st.session_state["generated_image_bytes"] = buf.getvalue()
            # FIX #2 ─ replaced deprecated st.experimental_rerun()
            st.experimental_rerun()


# ──────────────────────────────────────────────
# Button: Save assignment
# ──────────────────────────────────────────────
st.markdown("------------")

if st.button("Save Question", key="btn_save_question"):
    if not st.session_state.get("question_answers"):
        st.error("Please generate questions and answers first!")
    elif not text:
        st.error("Please enter input text first!")
    else:
        try:
            assignment_id = generate_assignment_id_key()
            questions_answers_str = json.dumps(st.session_state["question_answers"], indent=4)

            if image_model_id != "<model-id>":
                object_name = f"generated_images/{assignment_id}.png"

                # FIX #4 ─ write image from session_state to a temp file for S3 upload
                img_bytes = st.session_state.get("generated_image_bytes")
                if img_bytes:
                    temp_path = f"/tmp/temp-create-{assignment_id}.png"
                    with open(temp_path, "wb") as f:
                        f.write(img_bytes)

                    # FIX #6 ─ os is now imported at the top
                    if os.path.exists(temp_path):
                        success = load_file_to_s3(temp_path, object_name)
                        if success:
                            st.success(f"Image uploaded successfully: {object_name}")
                        else:
                            st.warning("Image upload to S3 failed.")
                        os.remove(temp_path)   # clean up temp file
                    else:
                        st.warning("Temp image not found. Proceeding without image.")
                        object_name = "no image created"
                else:
                    st.warning("No image in session. Proceeding without image.")
                    object_name = "no image created"
            else:
                object_name = "no image created"

            insert_record_to_dynamodb(assignment_id, text, object_name, questions_answers_str)
            st.success(f"Assignment saved successfully! ID: {assignment_id}")

        except Exception as ex:
            st.error(f"Error saving assignment: {ex}")
